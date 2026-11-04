import AppKit
import FarCore

/// A bounded, read-only viewport over an immutable random-access source.
/// The controller owns no writable file handles. Every source operation runs on a worker.
@MainActor
final class ViewerWindow: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    var macroEnvironment: MacroEnvironment {
        MacroEnvironment(context: .viewer, fileName: sourceURL.lastPathComponent, isDirectory: false,
                         hasSelection: textView.selectedRange().length > 0, isEditable: false)
    }
    static let helpText = """
    ПРОСМОТР — F3

    F2 — перенос в тексте или выход из дампа; F4 — hex и обратно; Shift+F4 — выбор текста / hex / дампа; F6 — открыть редактор в текущей позиции; F7 или Cmd+F — поле поиска. Shift+F7 или пробел в тексте — следующее совпадение, Option+F7 — предыдущее. Option+F8 — поле перехода. Home / End — начало / конец файла, Page Up / Down — прокрутка с переходом к соседнему блоку на границе; F10 в тексте — закрыть окно. Кнопки «Назад» / «Далее» читают соседние блоки. «Предыдущий файл» / «Следующий файл» и цифровые − / + открывают соседний обычный файл из порядка панели, захваченного при F3, без обхода по кругу. Папки и специальные файлы пропускаются. Изменённый, удалённый или недоступный сосед выдаёт ошибку; текущий файл остаётся открыт. Для рабочих копий архива/сервера и отдельных источников перехода нет. Esc отменяет текущую операцию; повторный Esc закрывает окно.

    Просмотр читает блоки до 64 КиБ; выделение и копирование доступны только внутри показанного блока. Блок может начинаться или заканчиваться посреди строки. Hex показывает точные байты с адресами, текст показывает выбранную кодировку. Дамп показывает по одной позиции на байт (UTF-16 — на два байта), 80 позиций в строке; переводы строк и Tab показаны видимыми знаками и не управляют отображением. В UTF-8 продолжения показаны ›; в UTF-16 пара суррогатов показана символом и ›. BOM виден как �. Точное совпадение ширины символов с консольными ячейками FAR не заявлено. F4 возвращает последний основной режим: текст или дамп. Автоопределение кодировки приблизительное; BOM и действующая кодировка показаны рядом с выбором. Недопустимые последовательности заменяются символом �.

    Переход: выберите байты, проценты или строку (с 1). Байты принимают десятичное число и 0xHEX; + / - задают смещение относительно текущей позиции. Суффикс % переключает на проценты; + / - также поддерживаются. Поиск строки и переход к строке выполняются в фоне; Esc или «Отменить» останавливает сканирование.

    Поиск: текст, регулярное выражение по отдельным строкам или hex-байты. Направление и регистр задаются явно. «Нестрогий поиск» в режиме «Текст» раскрывает лигатуры, совместимые формы и цифры Unicode и игнорирует неалфавитные диакритические знаки; регистр задаётся независимо. Границы и выделение остаются в исходном тексте, включая удаляемые комбинируемые знаки. Regex и Hex с этим флажком дают явный отказ. Настройки запоминаются, история хранит 20 запросов вместе с флажками. Контекст нестрогого поиска ограничен 262144 единицами UTF-16; слишком длинная цепочка комбинируемых знаков даёт явную ошибку неполного поиска. «Целые слова» учитывают буквы, цифры, подчёркивание и комбинируемые знаки Unicode; для hex этот флажок не применяется. «Искать по кругу» продолжает поиск с другой границы файла; без флажка поиск останавливается у границы. Регулярные выражения ограничены строкой до 1 МиБ и временем проверки; превышение ограничений выдаёт ошибку, а не «не найдено». Длинное совпадение выделяется только в пределах показанного блока. Пустое совпадение при повторном поиске продвигает позицию на один Unicode-символ.

    «Следить за файлом» обновляет конец локального файла раз в секунду, включая усечение и замену файла. Читается свежий блок до 64 КиБ через новый проверяемый источник; постоянная запись может задержать обновление до следующего опроса. Поиск и явный переход останавливают слежение. Для внешнего источника эта команда недоступна.

    Последняя позиция, режим, кодировка и перенос сохраняются для 100 файлов; для каждого файла можно сохранить 20 закладок. Замена или изменение файла сбрасывает позиции и закладки. Просмотр не записывает содержимое файла. Запись доступна только в отдельном редакторе, возможности которого могут быть уже возможностей просмотра.
    """

    private nonisolated static let pageSize = 65_536
    private static let historyKey = "viewer.history.v1"
    private static let searchSettingsKey = "viewer.search.settings.v1"
    private static let searchHistoryKey = "viewer.search.history.v1"
    private struct SearchSettings: Codable, Equatable {
        var pattern: String = ""
        var mode: Int = 0
        var caseSensitive: Bool = false
        var wholeWords: Bool = false
        var fuzzy: Bool = false
        var cycle: Bool = false
        var backwards: Bool = false
    }
    private struct Bookmark: Codable { var offset: Int64; var title: String }
    private struct History: Codable {
        var url: String
        var identity: String
        var offset: Int64 = 0
        var encoding: ViewerEncoding = .automatic
        var hex: Bool = false
        var dump: Bool? = nil
        var baseDump: Bool? = nil
        var wrap: Bool = true
        var bookmarks: [Bookmark] = []
        var accessed: Date = Date()
    }
    private struct Loaded: Sendable {
        let document: ViewerDocument
        let page: ViewerPage?
        let data: Data?
        let hexText: String?
        let logicalOffset: Int64
        let offset: Int64
        let selection: Range<Int64>?
    }

    private var sourceURL: URL
    private var navigation: ViewerNavigation?
    private let suppliedSource: (any ViewerByteSource)?
    private let onEdit: (URL, Int64, ViewerEncoding) -> Bool
    private let initialOffset: Int64?
    private let initialEncoding: ViewerEncoding
    private let initialDisplayMode: ViewerDisplayMode?
    private var viewerDocument: ViewerDocument?
    private var page: ViewerPage?
    private var hexData = Data()
    private var displayOffset: Int64 = 0
    private var displayEnd: Int64 = 0
    private(set) var currentByteOffset: Int64 = 0
    private var identity: String?
    private var isHex = false
    private var isDump = false
    private var baseMode: ViewerDisplayMode = .text
    private var wraps = true
    private var requestedEncoding: ViewerEncoding = .automatic
    private var generation = UUID()
    private var cancellation: ViewerCancellation?
    private var busyTitle = ""
    private var closed = false
    private var presenting = false
    var retainedArchiveWorkspace: ArchiveWorkspace?
    func showWorkingCopyLocation(_ path: String) {
        guard retainedArchiveWorkspace != nil || retainedRemoteWorkspace != nil else { return }
        pathLabel.stringValue = path
        window?.subtitle = path
    }
    var retainedRemoteWorkspace: RemoteWorkspace?
    var retainedRemoteLease: AnyObject?
    private var retainedWhileOpen: ViewerWindow?
    private var keyMonitor: Any?
    private var scrollObserver: NSObjectProtocol?
    private var lastSearchSignature: String?
    private var lastMatch: Range<Int64>?
    private var operationControls: [NSControl] = []
    private var followTimer: Timer?
    private var followPending = false
    private var followRevision = UUID()

    private let pathLabel = NSTextField(labelWithString: "")
    private let previousFileButton = NSButton(title: "Предыдущий файл · −", target: nil, action: nil)
    private let nextFileButton = NSButton(title: "Следующий файл · +", target: nil, action: nil)
    private let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 950, height: 450))
    private let scroll = NSScrollView()
    private let encoding = NSPopUpButton()
    private let mode = NSPopUpButton()
    private let wrapButton = NSButton(checkboxWithTitle: "Перенос · F2", target: nil, action: nil)
    private let followButton = NSButton(checkboxWithTitle: "Следить за файлом", target: nil, action: nil)
    private let effectiveEncoding = NSTextField(labelWithString: "Открытие…")
    private let position = NSTextField(string: "")
    private let positionMode = NSPopUpButton()
    private let searchField = NSTextField(string: "")
    private let searchMode = NSPopUpButton()
    private let searchDirection = NSPopUpButton()
    private let caseButton = NSButton(checkboxWithTitle: "Регистр", target: nil, action: nil)
    private let wordsButton = NSButton(checkboxWithTitle: "Целые слова", target: nil, action: nil)
    private let fuzzyButton = NSButton(checkboxWithTitle: "Нестрогий поиск", target: nil, action: nil)
    private let searchHistoryMenu = NSPopUpButton()
    private let cycleButton = NSButton(checkboxWithTitle: "Искать по кругу", target: nil, action: nil)
    private let bookmarkMenu = NSPopUpButton()
    private let historyMenu = NSPopUpButton()
    private let status = NSTextField(labelWithString: "Открытие файла…")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let cancelButton = NSButton(title: "Отменить · Esc", target: nil, action: nil)

    convenience init(url: URL, initialByteOffset: Int64? = nil, initialEncoding: ViewerEncoding = .automatic, initialDisplayMode: ViewerDisplayMode? = nil, navigation: ViewerNavigation? = nil, onEdit: @escaping (URL, Int64, ViewerEncoding) -> Bool) throws {
        self.init(source: nil, url: url, initialByteOffset: initialByteOffset, initialEncoding: initialEncoding, initialDisplayMode: initialDisplayMode, navigation: navigation, onEdit: onEdit)
    }

    convenience init(source: any ViewerByteSource, url: URL, initialByteOffset: Int64? = nil, initialEncoding: ViewerEncoding = .automatic,
                     initialDisplayMode: ViewerDisplayMode? = nil,
                     onEdit: @escaping (URL, Int64, ViewerEncoding) -> Bool) throws {
        self.init(source: Optional(source), url: url, initialByteOffset: initialByteOffset, initialEncoding: initialEncoding, initialDisplayMode: initialDisplayMode, navigation: nil, onEdit: onEdit)
    }

    private init(source: (any ViewerByteSource)?, url: URL, initialByteOffset: Int64?, initialEncoding: ViewerEncoding, initialDisplayMode: ViewerDisplayMode?, navigation: ViewerNavigation?,
                 onEdit: @escaping (URL, Int64, ViewerEncoding) -> Bool) {
        sourceURL = url.standardizedFileURL
        suppliedSource = source
        if source == nil, let navigation, navigation.urls[navigation.currentIndex] == url.standardizedFileURL {
            self.navigation = navigation
        }
        initialOffset = initialByteOffset
        self.initialEncoding = initialEncoding
        self.initialDisplayMode = initialDisplayMode
        self.onEdit = onEdit
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "\(sourceURL.lastPathComponent) — Просмотр"
        window.representedURL = sourceURL
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 1000, height: 500)
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        configureContent()
        installKeyboardMonitor()
        // Every viewer registers independently, including windows opened from history.
        // This runs only after AppKit has accepted termination, including Cmd+Q.
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillTerminate(_:)),
                                               name: NSApplication.willTerminateNotification, object: nil)
        openSource()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        followButton.isHidden = suppliedSource != nil || retainedArchiveWorkspace != nil || retainedRemoteWorkspace != nil
        if followButton.isHidden { navigation = nil }
        refreshFileButtons()
        if let view = window?.contentView { UIAccessibility.apply(to: view) }
        retainedWhileOpen = self
        super.showWindow(sender)
        window?.makeFirstResponder(textView)
    }

    private func button(_ title: String, _ action: Selector, tag: Int = 0) -> NSButton {
        let result = NSButton(title: title, target: self, action: action)
        result.bezelStyle = .rounded
        result.tag = tag
        return result
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        return stack
    }

    private func configureContent() {
        guard let content = window?.contentView else { return }
        let path = pathLabel
        path.stringValue = sourceURL.path
        path.lineBreakMode = .byTruncatingMiddle
        path.isSelectable = true
        path.font = .systemFont(ofSize: 12)
        encoding.addItems(withTitles: ViewerEncoding.allCases.map(\.title))
        encoding.target = self; encoding.action = #selector(encodingChanged)
        mode.addItems(withTitles: ["Текст", "Hex · F4", "Дамп"])
        mode.target = self; mode.action = #selector(modeChanged)
        wrapButton.state = .on; wrapButton.target = self; wrapButton.action = #selector(wrapChanged)
        followButton.target = self; followButton.action = #selector(followChanged)
        followButton.isHidden = suppliedSource != nil
        effectiveEncoding.font = .systemFont(ofSize: 11)
        effectiveEncoding.textColor = .secondaryLabelColor
        effectiveEncoding.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previousFileButton.target = self; previousFileButton.action = #selector(previousFileRequested)
        nextFileButton.target = self; nextFileButton.action = #selector(nextFileRequested)
        let fileNavigation = row([previousFileButton, nextFileButton])
        let formats = row([mode, encoding, wrapButton, effectiveEncoding,
                           button("Редактор · F6", #selector(editRequested))])
        position.placeholderString = "Смещение / % / строка"
        position.toolTip = "Байты: 123, 0xFF, +16, -16; проценты: 50%, +10%; строки с 1"
        position.cell?.sendsActionOnEndEditing = false
        position.target = self; position.action = #selector(goRequested)
        position.widthAnchor.constraint(equalToConstant: 170).isActive = true
        positionMode.addItems(withTitles: ["Байты", "%", "Строка"])
        cancelButton.target = self; cancelButton.action = #selector(cancelRequested)
        cancelButton.isEnabled = false
        let navigation = row([button("Начало", #selector(pageRequested), tag: -2),
                              button("Назад", #selector(pageRequested), tag: -1),
                              button("Далее", #selector(pageRequested), tag: 1),
                              button("Конец", #selector(pageRequested), tag: 2), position, positionMode,
                              button("Перейти", #selector(goRequested)), cancelButton])
        searchField.placeholderString = "Поиск · F7 / Cmd+F"
        searchField.cell?.sendsActionOnEndEditing = false
        searchField.target = self; searchField.action = #selector(searchRequested)
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        searchMode.addItems(withTitles: ["Текст", "Regex", "Hex"])
        searchDirection.addItems(withTitles: ["Вперёд", "Назад"])
        searchHistoryMenu.addItem(withTitle: "История поиска")
        searchHistoryMenu.target = self; searchHistoryMenu.action = #selector(searchHistorySelected)
        searchHistoryMenu.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let searching = row([searchField, searchMode,
                             searchHistoryMenu, button("Найти", #selector(searchRequested)),
                             button("Следующее", #selector(nextRequested)), button("Предыдущее", #selector(previousRequested))])
        let searchOptions = row([caseButton, wordsButton, fuzzyButton, cycleButton, searchDirection, followButton])
        fuzzyButton.toolTip = "Только текст: игнорировать диакритику, раскрывать лигатуры и совместимые Unicode-формы. Регистр задаётся отдельно."
        for control in [caseButton, wordsButton, fuzzyButton, cycleButton, searchDirection, searchMode] {
            control.target = self; control.action = #selector(searchSettingsChanged)
        }
        if let data = AppPreferences.defaults.data(forKey: Self.searchSettingsKey),
           let settings = try? JSONDecoder().decode(SearchSettings.self, from: data) { applySearchSettings(settings) }
        refreshSearchHistory()
        bookmarkMenu.target = self; bookmarkMenu.action = #selector(bookmarkSelected)
        bookmarkMenu.widthAnchor.constraint(equalToConstant: 240).isActive = true
        historyMenu.target = self; historyMenu.action = #selector(historySelected)
        historyMenu.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let hint = NSTextField(labelWithString: "Только чтение · выделение и копирование в показанном блоке")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bookmarks = row([bookmarkMenu, button("+ Закладка", #selector(addBookmark)),
                             button("Удалить", #selector(removeBookmark)), historyMenu, hint])
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder
        textView.isEditable = false; textView.isSelectable = true; textView.isRichText = false
        textView.importsGraphics = false; textView.allowsUndo = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = NSColor(calibratedRed: 0.035, green: 0.065, blue: 0.14, alpha: 1)
        textView.textColor = NSColor(calibratedRed: 0.88, green: 0.92, blue: 1, alpha: 1)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self
        scroll.documentView = textView
        scroll.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scrolled() }
            }
        status.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        message.font = .systemFont(ofSize: 11)
        message.textColor = .secondaryLabelColor
        message.maximumNumberOfLines = 2
        let footer = row([status, NSView(), button("Справка · F1", #selector(showViewerHelp)), button("Закрыть", #selector(closeRequested))])
        let stack = NSStackView(views: [path, formats, fileNavigation, navigation, searching, searchOptions, bookmarks, scroll, message, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        for view in [path, formats, fileNavigation, navigation, searching, searchOptions, bookmarks, scroll, message, footer] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        operationControls = [formats, navigation, searching, searchOptions, bookmarks].flatMap { $0.arrangedSubviews.compactMap { $0 as? NSControl } }.filter { $0 !== cancelButton && $0 !== wrapButton }
        operationControls.forEach { $0.isEnabled = false }
        updateWrap()
        refreshHistoryMenus()
    }

    private func openSource() {
        let supplied = suppliedSource, url = sourceURL
        work("Открытие файла", operation: { token, _ in
            if token.isCancelled { throw ViewerError.cancelled }
            return try supplied ?? LocalViewerSource(url: url)
        }) { [weak self] source in
            guard let self else { return }
            self.identity = source.identity
            let saved = Self.readHistory().first { $0.url == self.sourceURL.absoluteString }
            if let saved {
                self.requestedEncoding = saved.encoding; self.isHex = saved.hex; self.isDump = saved.dump == true && !saved.hex
                self.baseMode = (saved.baseDump ?? saved.dump) == true ? .dump : .text; self.wraps = saved.wrap
            }
            if self.initialEncoding != .automatic { self.requestedEncoding = self.initialEncoding }
            if let mode = self.initialDisplayMode {
                self.isHex = mode == .hex; self.isDump = mode == .dump
                if mode != .hex { self.baseMode = mode }
            }
            let offset = self.initialOffset ?? (saved?.identity == source.identity ? saved?.offset : nil) ?? 0
            self.encoding.selectItem(at: ViewerEncoding.allCases.firstIndex(of: self.requestedEncoding) ?? 0)
            self.mode.selectItem(at: self.isHex ? 1 : self.isDump ? 2 : 0)
            self.wrapButton.state = self.wraps ? .on : .off
            self.updateWrap()
            self.updateHistory(allowIdentityReset: true) { $0.accessed = Date() }
            self.openDocument(source: source, offset: offset)
        }
    }

    private func openDocument(source: any ViewerByteSource, offset: Int64) {
        let requested = requestedEncoding, hex = isHex, dump = isDump
        work("Чтение блока", operation: { token, _ in
            let document = try ViewerDocument(source: source, encoding: requested)
            if token.isCancelled { throw ViewerError.cancelled }
            return try Self.load(document, at: offset, hex: hex, dump: dump)
        }) { [weak self] loaded in self?.present(loaded) }
    }

    private nonisolated static func load(_ document: ViewerDocument, at offset: Int64, hex: Bool, dump: Bool = false,
                                         selection: Range<Int64>? = nil) throws -> Loaded {
        let bounded = min(max(0, offset), document.size)
        if hex {
            let start = bounded == document.size && bounded > 0 ? max(0, bounded - 1) / 16 * 16 : bounded / 16 * 16
            let data = try document.source.read(offset: start, count: pageSize)
            return Loaded(document: document, page: nil, data: data, hexText: hexString(data, at: start),
                          logicalOffset: bounded, offset: start, selection: selection)
        }
        let page = try dump ? document.dumpPage(at: bounded) : document.page(at: bounded)
        return Loaded(document: document, page: page, data: nil, hexText: nil, logicalOffset: page.startOffset, offset: page.startOffset, selection: selection)
    }

    private func loadPage(at offset: Int64, selection: Range<Int64>? = nil, scrollToEnd: Bool = false) {
        guard let document = viewerDocument else { return }
        let hex = isHex, dump = isDump
        work("Чтение блока", operation: { token, _ in
            if token.isCancelled { throw ViewerError.cancelled }
            return try Self.load(document, at: offset, hex: hex, dump: dump, selection: selection)
        }) { [weak self] loaded in
            guard let self else { return }
            self.present(loaded)
            if scrollToEnd {
                if let container = self.textView.textContainer { self.textView.layoutManager?.ensureLayout(for: container) }
                let bottom = max(0, self.textView.bounds.height - self.scroll.contentView.bounds.height)
                self.scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
                self.scroll.reflectScrolledClipView(self.scroll.contentView)
                self.scrolled()
            }
        }
    }

    private func present(_ loaded: Loaded) {
        presenting = true
        viewerDocument = loaded.document; operationControls.forEach { $0.isEnabled = true }; page = loaded.page; hexData = loaded.data ?? Data()
        displayOffset = loaded.offset
        displayEnd = loaded.page?.endOffset ?? (loaded.offset + Int64(hexData.count))
        currentByteOffset = loaded.selection?.lowerBound ?? loaded.logicalOffset
        textView.string = loaded.page?.text ?? loaded.hexText ?? ""
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        if let match = loaded.selection {
            if let page = loaded.page {
                let displayed = max(match.lowerBound, page.startOffset)..<min(max(match.upperBound, page.startOffset), page.endOffset)
                if let range = page.utf16Range(forByteRange: displayed) { textView.setSelectedRange(range) }
            } else {
                let relative = Int(max(0, match.lowerBound - displayOffset))
                let start = Self.hexCharacterOffset(relative)
                let available = max(0, min(Int(match.upperBound - match.lowerBound), hexData.count - relative))
                let end = available > 0 ? Self.hexCharacterOffset(relative + available - 1) + 2 : start
                textView.setSelectedRange(NSRange(location: min(start, textView.string.utf16.count),
                                                  length: max(0, min(end, textView.string.utf16.count) - start)))
            }
            textView.scrollRangeToVisible(textView.selectedRange())
        } else {
            scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        }
        effectiveEncoding.stringValue = "\(loaded.document.encoding.title) · BOM: \(loaded.document.bomLength) байт"
        message.stringValue = loaded.page?.invalidSequences == true ? "Недопустимые последовательности заменены на �. Можно выбрать другую кодировку или Hex." : ""
        if let match = loaded.selection, match.upperBound > displayEnd {
            message.stringValue = "Совпадение: \(match.lowerBound)..<\(match.upperBound). Выделена его часть в показанном блоке."
        }
        presenting = false
        window?.makeFirstResponder(textView)
        refreshStatus(); refreshHistoryMenus()
    }

    private nonisolated static func hexString(_ data: Data, at offset: Int64) -> String {
        let bytes = Array(data)
        var rows: [String] = []
        rows.reserveCapacity((bytes.count + 15) / 16)
        for start in stride(from: 0, to: bytes.count, by: 16) {
            let line = Array(bytes[start..<min(start + 16, bytes.count)])
            let hex = line.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = String(line.map { (32...126).contains($0) ? Character(Unicode.Scalar($0)) : "." })
            rows.append(String(format: "%016llX  ", offset + Int64(start)) + hex.padding(toLength: 47, withPad: " ", startingAt: 0) + "  |" + ascii.padding(toLength: 16, withPad: " ", startingAt: 0) + "|")
        }
        return rows.joined(separator: "\n")
    }

    private nonisolated static func hexCharacterOffset(_ byte: Int) -> Int { byte / 16 * 86 + 18 + byte % 16 * 3 }

    private func work<T: Sendable>(_ title: String,
        operation: @escaping (ViewerCancellation, @escaping (Int64) -> Void) throws -> T,
        completion: @escaping (T) -> Void) {
        cancelBackgroundWork()
        let id = UUID(), token = ViewerCancellation()
        generation = id; cancellation = token; busyTitle = title
        cancelButton.isEnabled = true; operationControls.forEach { $0.isEnabled = false }; refreshFileButtons()
        message.stringValue = ""; refreshStatus()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var lastProgress = Date.distantPast
            let progress: (Int64) -> Void = { offset in
                guard Date().timeIntervalSince(lastProgress) > 0.1 else { return }
                lastProgress = Date()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == id, !self.closed else { return }
                    self.refreshStatus(progress: offset)
                }
            }
            let result = Result { try operation(token, progress) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == id, !self.closed else { return }
                self.cancellation = nil; self.cancelButton.isEnabled = false; self.busyTitle = ""
                self.operationControls.forEach { $0.isEnabled = self.viewerDocument != nil }; self.refreshFileButtons()
                guard !token.isCancelled else { self.message.stringValue = "Операция отменена."; self.refreshStatus(); return }
                switch result {
                case .success(let value): completion(value)
                case .failure(let error): self.message.stringValue = error.localizedDescription
                }
                self.refreshStatus()
            }
        }
    }

    func cancelBackgroundWork() {
        cancellation?.cancel(); cancellation = nil; generation = UUID()
        busyTitle = ""; cancelButton.isEnabled = false
        operationControls.forEach { $0.isEnabled = viewerDocument != nil }; refreshFileButtons()
        refreshStatus()
    }

    private func refreshStatus(progress: Int64? = nil) {
        let size = viewerDocument?.size ?? 0
        let percent = size == 0 ? 0 : Double(currentByteOffset) / Double(size) * 100
        let base = "Байт \(currentByteOffset) / \(size) · \(String(format: "%.2f", percent))% · блок \(displayOffset)..<\(displayEnd)"
        status.stringValue = busyTitle.isEmpty ? base : "\(busyTitle)…\(progress.map { " \($0) байт" } ?? "") · Esc — отменить"
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !presenting, viewerDocument != nil else { return }
        currentByteOffset = offsetForCharacter(textView.selectedRange().location)
        refreshStatus()
    }

    private func offsetForCharacter(_ index: Int) -> Int64 {
        if let page { return page.byteOffset(forUTF16: index) }
        let line = index / 86, column = index % 86
        let byte = column >= 68 ? column - 68 : max(0, (column - 18) / 3)
        return min(displayEnd, displayOffset + Int64(line * 16 + min(byte, 15)))
    }

    private func scrolled() {
        guard !presenting, viewerDocument != nil, let container = textView.textContainer,
              let layout = textView.layoutManager else { return }
        var point = scroll.contentView.bounds.origin
        point.x = max(0, point.x - textView.textContainerInset.width)
        point.y = max(0, point.y - textView.textContainerInset.height)
        guard layout.numberOfGlyphs > 0 else { currentByteOffset = displayOffset; refreshStatus(); return }
        let glyph = layout.glyphIndex(for: point, in: container)
        let character = layout.characterIndexForGlyph(at: min(glyph, max(0, layout.numberOfGlyphs - 1)))
        currentByteOffset = offsetForCharacter(character); refreshStatus()
    }

    @objc private func pageRequested(_ sender: NSButton) {
        stopFollowing()
        guard let document = viewerDocument, cancellation == nil else { return }
        lastMatch = nil
        switch sender.tag {
        case -2: loadPage(at: 0)
        case -1: loadPage(at: max(0, displayOffset - Int64(Self.pageSize)))
        case 2: loadPage(at: max(0, document.size - Int64(Self.pageSize)))
        default: if displayEnd < document.size { loadPage(at: displayEnd) }
        }
    }

    @objc private func encodingChanged() {
        requestedEncoding = ViewerEncoding.allCases[encoding.indexOfSelectedItem]
        let selected = requestedEncoding
        updateHistory { $0.encoding = selected }
        lastMatch = nil
        if let source = viewerDocument?.source { openDocument(source: source, offset: currentByteOffset) }
    }

    @objc private func modeChanged() { applyMode(updateBase: true) }

    private func applyMode(updateBase: Bool) {
        isHex = mode.indexOfSelectedItem == 1
        isDump = mode.indexOfSelectedItem == 2
        if updateBase && !isHex { baseMode = isDump ? .dump : .text }
        let selected = isHex, dump = isDump, baseDump = baseMode == .dump
        updateHistory { $0.hex = selected; $0.dump = dump; $0.baseDump = baseDump }
        updateWrap(); loadPage(at: currentByteOffset)
    }

    private func toggleHex() {
        mode.selectItem(at: isHex ? (baseMode == .dump ? 2 : 0) : 1)
        applyMode(updateBase: false)
    }

    private func f2Requested() {
        guard cancellation == nil else { return }
        if !isHex && !isDump { wrapButton.state = wraps ? .off : .on; wrapChanged() }
        else { mode.selectItem(at: isDump || baseMode == .dump ? 0 : 2); applyMode(updateBase: false) }
    }

    private func refreshFileButtons() {
        let available = suppliedSource == nil && retainedArchiveWorkspace == nil && retainedRemoteWorkspace == nil
        previousFileButton.isHidden = !available || navigation == nil
        nextFileButton.isHidden = previousFileButton.isHidden
        previousFileButton.isEnabled = available && cancellation == nil && navigation?.adjacentIndex(forward: false) != nil
        nextFileButton.isEnabled = available && cancellation == nil && navigation?.adjacentIndex(forward: true) != nil
    }

    @objc private func previousFileRequested() { navigateFile(forward: false) }
    @objc private func nextFileRequested() { navigateFile(forward: true) }

    private func navigateFile(forward: Bool) {
        guard cancellation == nil, suppliedSource == nil, retainedArchiveWorkspace == nil, retainedRemoteWorkspace == nil,
              let navigation, let index = navigation.adjacentIndex(forward: forward) else { return }
        stopFollowing()
        let target = navigation.urls[index]
        let saved = Self.readHistory().first { $0.url == target.absoluteString }
        let requested = saved?.encoding ?? requestedEncoding, hex = isHex, dump = isDump
        let baseDump = baseMode == .dump
        work("Открытие соседнего файла", operation: { token, _ in
            let source = try navigation.source(at: index, cancellation: token)
            let document = try ViewerDocument(source: source, encoding: requested)
            let offset = saved?.identity == source.identity ? saved?.offset ?? 0 : 0
            let loaded = try Self.load(document, at: offset, hex: hex, dump: dump)
            try source.verifyUnchanged()
            if token.isCancelled { throw ViewerError.cancelled }
            return loaded
        }) { [weak self] loaded in
            guard let self else { return }
            let previousOffset = self.currentByteOffset
            self.updateHistory { $0.offset = previousOffset }
            self.sourceURL = target; self.navigation = try? navigation.moving(to: index)
            self.identity = loaded.document.source.identity; self.requestedEncoding = requested
            self.encoding.selectItem(at: ViewerEncoding.allCases.firstIndex(of: requested) ?? 0)
            self.pathLabel.stringValue = target.path
            self.window?.title = "\(target.lastPathComponent) — Просмотр"; self.window?.representedURL = target
            self.lastMatch = nil; self.lastSearchSignature = nil
            self.updateHistory(allowIdentityReset: true) { $0.accessed = Date(); $0.hex = hex; $0.dump = dump; $0.baseDump = baseDump }
            self.present(loaded); self.refreshFileButtons()
        }
    }

    @objc private func wrapChanged() {
        wraps = wrapButton.state == .on
        let selected = wraps
        updateHistory { $0.wrap = selected }
        updateWrap()
    }

    private func updateWrap() {
        wrapButton.isEnabled = !isHex && !isDump
        wrapButton.toolTip = "F2: перенос в тексте; из дампа — текст; из hex — режим, противоположный основному"
        let wrap = wraps && !isHex && !isDump
        textView.isHorizontallyResizable = !wrap
        textView.autoresizingMask = wrap ? [.width] : []
        textView.textContainer?.widthTracksTextView = wrap
        textView.textContainer?.containerSize = NSSize(width: wrap ? max(100, scroll.contentSize.width - 24) : .greatestFiniteMagnitude,
                                                     height: .greatestFiniteMagnitude)
        if wrap { textView.setFrameSize(NSSize(width: max(100, scroll.contentSize.width), height: textView.frame.height)) }
    }

    @objc private func goRequested() {
        stopFollowing()
        guard let document = viewerDocument else { return }
        let text = position.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let relative = text.hasPrefix("+") || text.hasPrefix("-")
        if positionMode.indexOfSelectedItem == 2, !text.hasSuffix("%") {
            guard let line = Int64(text), line > 0, !relative else { message.stringValue = "Номер строки — целое число с 1."; return }
            let hex = isHex, dump = isDump
            work("Переход к строке \(line)", operation: { token, progress in
                let offset = try document.offset(ofLine: line, cancellation: token, onProgress: progress)
                return try Self.load(document, at: offset, hex: hex, dump: dump)
            }) { [weak self] loaded in self?.lastMatch = nil; self?.present(loaded) }
            return
        }
        let percent = text.hasSuffix("%") || positionMode.indexOfSelectedItem == 1
        var raw = text.hasSuffix("%") ? String(text.dropLast()) : text
        var sign: Int64 = 1
        if raw.hasPrefix("-") { sign = -1; raw.removeFirst() }
        else if raw.hasPrefix("+") { raw.removeFirst() }
        let offset: Int64
        if percent {
            guard let number = Double(raw), number.isFinite, number >= 0, number <= 100 else { message.stringValue = "Процент должен быть от 0 до 100."; return }
            let delta = Double(document.size) * number / 100
            let proposed = Double(relative ? currentByteOffset : 0) + Double(sign) * delta
            if proposed >= Double(document.size) { offset = document.size }
            else if proposed <= 0 { offset = 0 }
            else { offset = Int64(proposed.rounded(.towardZero)) }
        } else {
            let value: Int64?
            if raw.lowercased().hasPrefix("0x") { value = Int64(raw.dropFirst(2), radix: 16) }
            else { value = Int64(raw) }
            guard let value, value >= 0 else { message.stringValue = "Введите смещение в байтах: 123, 0xFF, +16 или -16."; return }
            let (candidate, overflow) = (relative ? currentByteOffset : 0).addingReportingOverflow(sign * value)
            guard !overflow, candidate >= 0, candidate <= document.size else { message.stringValue = "Смещение за пределами файла."; return }
            offset = candidate
        }
        lastMatch = nil; loadPage(at: offset)
    }

    @objc private func followChanged() {
        if followButton.state != .on { stopFollowing(); return }
        guard suppliedSource == nil, retainedArchiveWorkspace == nil, retainedRemoteWorkspace == nil else { stopFollowing(); return }
        followRevision = UUID()
        followTimer?.invalidate()
        followTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollFollow() }
        }
        pollFollow(force: true)
    }

    private func stopFollowing() {
        followTimer?.invalidate(); followTimer = nil; followButton.state = .off; followRevision = UUID()
    }

    private func pollFollow(force: Bool = false) {
        guard !closed, followButton.state == .on, !followPending, cancellation == nil else { return }
        followPending = true
        let revision = followRevision, operation = generation
        let url = sourceURL, previous = force ? nil : viewerDocument?.source.identity
        let requested = requestedEncoding, hex = isHex, dump = isDump
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result: Result<Loaded?, Error> = Result {
                guard let update = try ViewerTail.poll(url: url, previousIdentity: previous, encoding: requested) else { return nil }
                return try Self.load(update.document, at: update.offset, hex: hex, dump: dump)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.followPending = false
                guard !self.closed, self.followButton.state == .on, self.followRevision == revision,
                      self.generation == operation, self.cancellation == nil else { return }
                switch result {
                case .success(let loaded):
                    guard let loaded else { return }
                    if self.identity != loaded.document.source.identity {
                        self.identity = loaded.document.source.identity
                        self.updateHistory(allowIdentityReset: true) { $0.offset = loaded.offset }
                    }
                    let responder = self.window?.firstResponder
                    self.lastMatch = nil; self.present(loaded)
                    if let responder { self.window?.makeFirstResponder(responder) }
                    self.textView.scrollRangeToVisible(NSRange(location: self.textView.string.utf16.count, length: 0))
                    self.message.stringValue = "Слежение: конец файла обновляется раз в секунду. Поиск и переход останавливают слежение."
                case .failure(let error):
                    // A busy writer can change between snapshot and page read. Retry
                    // next tick; other errors require an explicit restart.
                    if let viewerError = error as? ViewerError, viewerError == .changedFile { return }
                    self.stopFollowing(); self.message.stringValue = error.localizedDescription
                }
            }
        }
    }

    @objc private func searchRequested() { search(direction: searchDirection.indexOfSelectedItem == 1 ? .backward : .forward, repeatSearch: false) }
    @objc private func nextRequested() { search(direction: .forward, repeatSearch: true) }
    @objc private func previousRequested() { search(direction: .backward, repeatSearch: true) }

    private func search(direction: ViewerSearchDirection, repeatSearch: Bool) {
        stopFollowing()
        guard let document = viewerDocument else { return }
        let modes: [ViewerSearchMode] = [.literal, .regex, .hex]
        let query = ViewerSearchQuery(pattern: searchField.stringValue, mode: modes[searchMode.indexOfSelectedItem], caseSensitive: caseButton.state == .on, wholeWords: wordsButton.state == .on, fuzzy: fuzzyButton.state == .on)
        do { try ViewerSearch.validate(query) }
        catch { message.stringValue = error.localizedDescription; return }
        saveSearchSettings(recordHistory: !repeatSearch)
        let cycle = cycleButton.state == .on
        let signature = "\(searchMode.indexOfSelectedItem):\(caseButton.state.rawValue):\(wordsButton.state.rawValue):\(fuzzyButton.state.rawValue):\(cycle):\(searchField.stringValue)"
        let previous = repeatSearch && signature == lastSearchSignature ? lastMatch : nil
        let current = currentByteOffset, hex = isHex, dump = isDump
        lastSearchSignature = signature
        work("Поиск", operation: { token, progress in
            try ViewerSearch.validate(query)
            var from = current
            if let previous {
                if direction == .backward { from = previous.lowerBound }
                else if previous.isEmpty {
                    if previous.lowerBound >= document.size {
                        if !cycle { return Optional<Loaded>.none }
                        from = 0
                    } else {
                        let page = try document.page(at: previous.lowerBound)
                        let width = page.text.unicodeScalars.first.map { $0.value > 0xFFFF ? 2 : 1 } ?? 1
                        from = page.byteOffset(forUTF16: width)
                        if from <= previous.lowerBound { from = previous.lowerBound + 1 }
                    }
                } else { from = previous.upperBound }
            }
            guard let found = try ViewerSearch.find(document: document, query: query, from: from,
                                                    direction: direction, wrap: cycle, cancellation: token, onProgress: progress) else { return Optional<Loaded>.none }
            return try Optional(Self.load(document, at: found.byteRange.lowerBound, hex: hex, dump: dump, selection: found.byteRange))
        }) { [weak self] loaded in
            guard let self else { return }
            guard let loaded else { self.message.stringValue = cycle ? "Совпадений нет во всём файле." : "Совпадение не найдено до \(direction == .forward ? "конца" : "начала") файла. Поиск без перехода через границу."; return }
            self.lastMatch = loaded.selection; self.present(loaded)
        }
    }

    @objc private func editRequested() {
        guard cancellation == nil else {
            message.stringValue = "Дождитесь загрузки выбранной кодировки или отмените операцию перед переходом в редактор."
            return
        }
        guard let document = viewerDocument else { return }
        guard document.size <= 8 * 1_024 * 1_024 else {
            message.stringValue = "Редактор поддерживает файлы до 8 МиБ. Продолжайте просмотр большого файла в этом окне."
            return
        }
        let offset = currentByteOffset
        cancelBackgroundWork()
        if onEdit(sourceURL, offset, document.encoding) { window?.close() }
    }

    @objc private func cancelRequested() { cancelBackgroundWork(); message.stringValue = "Операция отменена." }

    private var searchSettings: SearchSettings {
        SearchSettings(pattern: searchField.stringValue, mode: searchMode.indexOfSelectedItem,
                       caseSensitive: caseButton.state == .on, wholeWords: wordsButton.state == .on,
                       fuzzy: fuzzyButton.state == .on, cycle: cycleButton.state == .on,
                       backwards: searchDirection.indexOfSelectedItem == 1)
    }

    private func applySearchSettings(_ settings: SearchSettings) {
        searchField.stringValue = settings.pattern
        searchMode.selectItem(at: min(2, max(0, settings.mode)))
        caseButton.state = settings.caseSensitive ? .on : .off; wordsButton.state = settings.wholeWords ? .on : .off
        fuzzyButton.state = settings.fuzzy ? .on : .off; cycleButton.state = settings.cycle ? .on : .off
        searchDirection.selectItem(at: settings.backwards ? 1 : 0)
        lastMatch = nil; lastSearchSignature = nil
    }

    private static func readSearchHistory() -> [SearchSettings] {
        guard let data = AppPreferences.defaults.data(forKey: searchHistoryKey),
              let entries = try? JSONDecoder().decode([SearchSettings].self, from: data) else { return [] }
        return Array(entries.prefix(20))
    }

    private func refreshSearchHistory() {
        searchHistoryMenu.removeAllItems(); searchHistoryMenu.addItem(withTitle: "История поиска")
        for (index, entry) in Self.readSearchHistory().enumerated() {
            searchHistoryMenu.addItem(withTitle: "\(entry.fuzzy ? "≈ " : "")\(String(entry.pattern.prefix(40)))")
            searchHistoryMenu.lastItem?.representedObject = index
            searchHistoryMenu.lastItem?.toolTip = entry.pattern
        }
    }

    private func saveSearchSettings(recordHistory: Bool) {
        let settings = searchSettings
        if let data = try? JSONEncoder().encode(settings) { AppPreferences.defaults.set(data, forKey: Self.searchSettingsKey) }
        if recordHistory {
            var entries = Self.readSearchHistory(); entries.removeAll { $0 == settings }; entries.insert(settings, at: 0)
            if let data = try? JSONEncoder().encode(Array(entries.prefix(20))) { AppPreferences.defaults.set(data, forKey: Self.searchHistoryKey) }
            refreshSearchHistory()
        }
    }

    @objc private func searchSettingsChanged() { lastMatch = nil; lastSearchSignature = nil; saveSearchSettings(recordHistory: false) }
    @objc private func searchHistorySelected() {
        guard let index = searchHistoryMenu.selectedItem?.representedObject as? Int else { return }
        let entries = Self.readSearchHistory(); guard entries.indices.contains(index) else { return }
        applySearchSettings(entries[index]); saveSearchSettings(recordHistory: false); searchHistoryMenu.selectItem(at: 0)
    }
    @objc private func closeRequested() { window?.performClose(nil) }
    @objc private func showViewerHelp() {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = "Просмотр файлов"
        alert.informativeText = Self.helpText
        alert.addButton(withTitle: "Закрыть")
        alert.beginSheetModal(for: window)
    }

    private func installKeyboardMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, event.window === self.window, self.window?.isKeyWindow == true,
                      self.window?.attachedSheet == nil else { return false }
                if CommandWorkspace.shared.handle(event) { return true }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let key = event.keyCode
                if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "f" {
                    self.searchField.selectText(nil); return true
                }
                if key == 53 {
                    if self.cancellation != nil { self.cancelRequested() } else { self.closeRequested() }
                    return true
                }
                if key == 122 { self.showViewerHelp(); return true } // F1
                if key == 99 { // F3 closes viewer, as in FAR.
                    if self.cancellation != nil { self.cancelRequested() } else { self.closeRequested() }
                    return true
                }
                if key == 120 { self.f2Requested(); return true }
                if key == 118 {
                    guard self.cancellation == nil else { return true }
                    if flags.contains(.shift) { self.mode.performClick(nil) }
                    else { self.toggleHex() }; return true
                } // F4
                if key == 97 { self.editRequested(); return true }
                if key == 98 {
                    if flags.contains(.option) { self.previousRequested() }
                    else if flags.contains(.shift) { self.nextRequested() }
                    else { self.searchField.selectText(nil) }
                    return true
                }
                if key == 100, flags.contains(.option) {
                    self.position.selectText(nil); return true
                }
                let isTextFocus = self.window?.firstResponder === self.textView
                if isTextFocus && flags.intersection([.command, .option, .control, .shift]).isEmpty && (key == 69 || key == 78) {
                    self.navigateFile(forward: key == 69); return true
                }
                if isTextFocus && key == 49 && flags.intersection([.command, .option, .control, .shift]).isEmpty {
                    self.nextRequested(); return true
                }
                if isTextFocus && key == 109 { // F10
                    if self.cancellation != nil { self.cancelRequested() } else { self.closeRequested() }
                    return true
                }
                if isTextFocus && self.cancellation == nil && (key == 116 || key == 121), let document = self.viewerDocument {
                    let visible = self.scroll.documentVisibleRect
                    if key == 121 && visible.maxY >= self.textView.bounds.maxY - 1 && self.displayEnd < document.size {
                        self.lastMatch = nil
                        self.loadPage(at: self.displayEnd)
                        return true
                    }
                    if key == 116 && visible.minY <= 1 && self.displayOffset > 0 {
                        self.lastMatch = nil
                        self.loadPage(at: max(0, self.displayOffset - Int64(Self.pageSize)), scrollToEnd: true)
                        return true
                    }
                    // Let NSTextView scroll within the currently loaded block.
                }
                if isTextFocus && (key == 115 || key == 119) {
                    self.pageRequested(NSButtonWithTag(key == 115 ? -2 : 2)); return true
                }
                return false
            }
            return consumed ? nil : event
        }
    }

    private static func readHistory() -> [History] {
        guard let data = AppPreferences.defaults.data(forKey: historyKey), let entries = try? JSONDecoder().decode([History].self, from: data) else { return [] }
        return Array(entries.prefix(100)).map { entry in
            var entry = entry; entry.bookmarks = Array(entry.bookmarks.prefix(20)); return entry
        }
    }

    /// Each write merges into the current store; another window's newer settings survive a close.
    private func updateHistory(allowIdentityReset: Bool = false, _ mutate: (inout History) -> Void) {
        guard retainedArchiveWorkspace == nil, retainedRemoteWorkspace == nil else { return }
        guard let identity else { return }
        var entries = Self.readHistory()
        let index = entries.firstIndex { $0.url == sourceURL.absoluteString }
        var entry = index.map { entries[$0] } ?? History(url: sourceURL.absoluteString, identity: identity)
        if entry.identity != identity {
            guard allowIdentityReset else { return }
            entry.identity = identity; entry.offset = 0; entry.bookmarks = []
        }
        mutate(&entry)
        entry.bookmarks = Array(entry.bookmarks.prefix(20))
        if let index { entries[index] = entry } else { entries.append(entry) }
        entries.sort { $0.accessed > $1.accessed }
        if let data = try? JSONEncoder().encode(Array(entries.prefix(100))) { AppPreferences.defaults.set(data, forKey: Self.historyKey) }
        refreshHistoryMenus()
    }

    private func refreshHistoryMenus() {
        let entries = Self.readHistory()
        let saved = entries.first { $0.url == sourceURL.absoluteString && $0.identity == identity }
        let selectedOffset = bookmarkMenu.selectedItem?.representedObject as? Int64
        bookmarkMenu.removeAllItems(); bookmarkMenu.addItem(withTitle: "Закладки (\(saved?.bookmarks.count ?? 0)/20)")
        for bookmark in saved?.bookmarks ?? [] {
            bookmarkMenu.addItem(withTitle: bookmark.title)
            bookmarkMenu.lastItem?.representedObject = bookmark.offset
            if bookmark.offset == selectedOffset { bookmarkMenu.selectItem(at: bookmarkMenu.numberOfItems - 1) }
        }
        historyMenu.removeAllItems(); historyMenu.addItem(withTitle: "История просмотра")
        for entry in entries {
            historyMenu.addItem(withTitle: URL(string: entry.url)?.lastPathComponent ?? entry.url)
            historyMenu.lastItem?.representedObject = entry.url
            historyMenu.lastItem?.toolTip = URL(string: entry.url)?.path
        }
    }

    @objc private func addBookmark() {
        guard viewerDocument != nil else { return }
        let offset = currentByteOffset
        updateHistory { entry in
            guard !entry.bookmarks.contains(where: { $0.offset == offset }) else { return }
            if entry.bookmarks.count == 20 { entry.bookmarks.removeFirst() }
            entry.bookmarks.append(Bookmark(offset: offset, title: "Байт \(offset)"))
        }
    }

    @objc private func removeBookmark() {
        guard let offset = bookmarkMenu.selectedItem?.representedObject as? Int64 else { message.stringValue = "Выберите закладку для удаления."; return }
        updateHistory { $0.bookmarks.removeAll { $0.offset == offset } }
    }

    @objc private func bookmarkSelected() {
        stopFollowing()
        guard let offset = bookmarkMenu.selectedItem?.representedObject as? Int64 else { return }
        lastMatch = nil; loadPage(at: offset)
    }

    @objc private func historySelected() {
        guard let string = historyMenu.selectedItem?.representedObject as? String, let url = URL(string: string), url.isFileURL else { return }
        do { let viewer = try ViewerWindow(url: url, onEdit: onEdit); viewer.showWindow(nil) }
        catch { message.stringValue = error.localizedDescription }
        historyMenu.selectItem(at: 0)
    }

    private func savePositionAndCancel() {
        guard !closed else { return }
        stopFollowing()
        let offset = currentByteOffset
        updateHistory { $0.offset = offset }
        closed = true
        cancelBackgroundWork()
    }

    @objc private func applicationWillTerminate(_ notification: Notification) {
        savePositionAndCancel()
    }

    func windowWillClose(_ notification: Notification) {
        savePositionAndCancel()
        retainedArchiveWorkspace = nil
        retainedRemoteWorkspace = nil
        retainedRemoteLease = nil
        NotificationCenter.default.removeObserver(self, name: NSApplication.willTerminateNotification, object: nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver); self.scrollObserver = nil }
        window?.delegate = nil
        retainedWhileOpen = nil
    }
}

@MainActor
private func NSButtonWithTag(_ tag: Int) -> NSButton {
    let button = NSButton(); button.tag = tag; return button
}

extension ViewerWindow {
    static func registerAutomation(in workspace: CommandWorkspace) {
        workspace.register("viewer.wrap", title: "Перенос строк в просмотрщике", contexts: [.viewer], recordable: true) {
            guard let viewer = NSApp.keyWindow?.windowController as? ViewerWindow, viewer.cancellation == nil else { throw CommandRegistryError.contextMismatch }
            viewer.wrapButton.state = viewer.wraps ? .off : .on; viewer.wrapChanged()
        }
        workspace.register("viewer.f2", title: "F2: перенос / режим просмотра", contexts: [.viewer], recordable: true) {
            guard let viewer = NSApp.keyWindow?.windowController as? ViewerWindow, viewer.cancellation == nil else { throw CommandRegistryError.contextMismatch }
            viewer.f2Requested()
        }
        for (id, title) in [("viewer.mode", "Hex / основной режим"), ("viewer.next", "Следующее совпадение"), ("viewer.previous", "Предыдущее совпадение"),
                            ("viewer.dump", "Дамп"), ("viewer.nextFile", "Следующий файл панели"), ("viewer.previousFile", "Предыдущий файл панели")] {
            workspace.register(id, title: title, contexts: [.viewer]) {
                guard let viewer = NSApp.keyWindow?.windowController as? ViewerWindow, viewer.cancellation == nil else { throw CommandRegistryError.contextMismatch }
                if id == "viewer.mode" { viewer.toggleHex() }
                else if id == "viewer.dump" { viewer.mode.selectItem(at: 2); viewer.modeChanged() }
                else if id == "viewer.nextFile" || id == "viewer.previousFile" {
                    let forward = id == "viewer.nextFile"
                    guard viewer.suppliedSource == nil, viewer.retainedArchiveWorkspace == nil, viewer.retainedRemoteWorkspace == nil,
                          viewer.navigation?.adjacentIndex(forward: forward) != nil else { throw CommandRegistryError.contextMismatch }
                    viewer.navigateFile(forward: forward)
                }
                else if id == "viewer.next" { viewer.nextRequested() }
                else { viewer.previousRequested() }
            }
        }
    }
    func automationKey(_ event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        return event.keyCode == 120 && flags.isEmpty ? "viewer.f2" : nil
    }
    var extensionText: String { textView.string }
}

extension ViewerWindow {
    static func runViewerFuzzyUISmokeChecks() async throws -> [String] {
        let directory = AppRuntime.smokeDirectory ?? FileManager.default.temporaryDirectory
        let url = directory.appendingPathComponent("viewer-fuzzy-smoke.txt")
        try Data("🙂café cafe\u{301} Æ\n".utf8).write(to: url)
        let savedSettings = AppPreferences.defaults.data(forKey: Self.searchSettingsKey)
        let savedHistory = AppPreferences.defaults.data(forKey: Self.searchHistoryKey)
        let viewer = try ViewerWindow(url: url, onEdit: { _, _, _ in false })
        defer {
            viewer.window?.close(); try? FileManager.default.removeItem(at: url)
            if let savedSettings { AppPreferences.defaults.set(savedSettings, forKey: Self.searchSettingsKey) }
            else { AppPreferences.defaults.removeObject(forKey: Self.searchSettingsKey) }
            if let savedHistory { AppPreferences.defaults.set(savedHistory, forKey: Self.searchHistoryKey) }
            else { AppPreferences.defaults.removeObject(forKey: Self.searchHistoryKey) }
        }
        func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
            if !value() { throw NSError(domain: "ViewerFuzzySmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func settle(_ window: ViewerWindow) async throws {
            let deadline = Date().addingTimeInterval(8)
            while window.cancellation != nil && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            try require(window.cancellation == nil && window.viewerDocument != nil, "Fuzzy viewer worker completes")
        }
        viewer.showWindow(nil); try await settle(viewer)
        viewer.applySearchSettings(SearchSettings(pattern: "cafe", wholeWords: true, fuzzy: true, cycle: true))
        viewer.searchRequested(); try await settle(viewer)
        try require(viewer.lastMatch == 4..<9, "Fuzzy viewer selects original UTF-8 accent range")
        viewer.nextRequested(); try await settle(viewer)
        try require(viewer.lastMatch == 10..<16 && viewer.textView.selectedRange().length == 5, "Repeat selects full decomposed original range")
        viewer.nextRequested(); try await settle(viewer)
        try require(viewer.lastMatch == 4..<9, "Fuzzy viewer wraps with original offsets")
        let restored = try ViewerWindow(url: url, initialByteOffset: 10, initialDisplayMode: .hex, onEdit: { _, _, _ in false })
        defer { restored.window?.close() }
        restored.showWindow(nil); try await settle(restored)
        try require(restored.fuzzyButton.state == .on && restored.wordsButton.state == .on && restored.cycleButton.state == .on, "Fuzzy controls persist into another window")
        try require(restored.isHex && !restored.isDump && restored.currentByteOffset == 10 && restored.textView.string.hasPrefix("0000000000000000"), "Explicit hex byte position overrides saved viewer text mode")
        restored.fuzzyButton.state = .off; restored.searchField.stringValue = "changed"
        restored.searchHistoryMenu.selectItem(at: 1); restored.searchHistorySelected()
        try require(restored.fuzzyButton.state == .on && restored.searchField.stringValue == "cafe", "Search history restores fuzzy and pattern together")
        let oldMatch = viewer.lastMatch
        viewer.searchMode.selectItem(at: 1); viewer.searchRequested()
        try require(viewer.cancellation == nil && viewer.lastMatch == oldMatch && viewer.message.stringValue.contains("только"), "Fuzzy plus regex reports unsupported mode without changing selection")
        return ["Viewer fuzzy original byte highlights", "Viewer fuzzy next and wrap", "Viewer fuzzy settings and search history", "Viewer fuzzy rejects regex", "Viewer initial hex mode and byte offset override history"]
    }

    static func runViewerUISmokeChecks() async throws -> [String] {
        let directory = AppRuntime.smokeDirectory ?? FileManager.default.temporaryDirectory
        let url = directory.appendingPathComponent("viewer-options-smoke.txt")
        try Data("cats cat\n".utf8).write(to: url)
        var editedURL: URL?
        let viewer = try ViewerWindow(url: url, onEdit: { url, _, _ in editedURL = url; return false })
        defer { viewer.window?.close(); try? FileManager.default.removeItem(at: url) }
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw NSError(domain: "ViewerSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func settle() async throws {
            let deadline = Date().addingTimeInterval(5)
            while (viewer.cancellation != nil || viewer.followPending) && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            try require(viewer.cancellation == nil && !viewer.followPending, "Viewer worker completes")
        }
        viewer.showWindow(nil); try await settle()
        viewer.applySearchSettings(SearchSettings(pattern: "cat", wholeWords: true))
        viewer.searchRequested(); try await settle()
        try require(viewer.lastMatch == 5..<8, "Viewer whole words select exact result")
        viewer.cycleButton.state = .on; viewer.nextRequested(); try await settle()
        viewer.nextRequested(); try await settle()
        try require(viewer.lastMatch == 5..<8, "Viewer cyclic search repeats after boundary")
        viewer.followButton.state = .on; viewer.followChanged(); try await settle()
        let handle = try FileHandle(forWritingTo: url); try handle.seekToEnd(); try handle.write(contentsOf: Data("appended🙂\n".utf8)); try handle.close()
        viewer.pollFollow(); try await settle()
        try require(viewer.textView.string.hasSuffix("appended🙂\n"), "Viewer follows growing local file")
        viewer.searchRequested(); try await settle()
        try require(viewer.followButton.state == .off && viewer.followTimer == nil, "Search stops viewer follow")
        viewer.mode.selectItem(at: 2); viewer.modeChanged(); try await settle()
        try require(viewer.isDump && viewer.textView.string.contains("␊") && viewer.textView.string.contains("›"), "Dump renders code units without interpreting source newlines")
        viewer.toggleHex(); try await settle()
        try require(viewer.isHex && viewer.textView.string.hasPrefix("0000000000000000"), "F4 switches dump to hex")
        viewer.toggleHex(); try await settle()
        try require(viewer.isDump && !viewer.isHex, "F4 returns to dump base mode")
        viewer.f2Requested(); try await settle()
        try require(!viewer.isHex && !viewer.isDump, "F2 switches dump to text")
        viewer.mode.selectItem(at: 0); viewer.modeChanged(); try await settle()
        viewer.toggleHex(); try await settle()
        viewer.f2Requested(); try await settle()
        try require(viewer.isDump && viewer.baseMode == .text, "F2 from hex selects mode opposite menu base without changing base")
        viewer.toggleHex(); try await settle(); viewer.toggleHex(); try await settle()
        try require(!viewer.isDump && !viewer.isHex, "F4 still returns to menu text base")

        let adjacent = directory.appendingPathComponent("viewer-neighbor-smoke.txt")
        try Data("neighbor Ж🙂\n".utf8).write(to: adjacent)
        defer { try? FileManager.default.removeItem(at: adjacent) }
        viewer.navigation = try ViewerNavigation(urls: [url, adjacent], currentURL: url)
        viewer.refreshFileButtons()
        try require(viewer.nextFileButton.isEnabled && !viewer.previousFileButton.isEnabled, "Captured panel navigation exposes correct boundaries")
        viewer.nextFileRequested(); try await settle()
        try require(viewer.sourceURL == adjacent && viewer.textView.string == "neighbor Ж🙂\n", "Neighbor opens in the same viewer")
        try require(viewer.window?.representedURL == adjacent && viewer.pathLabel.stringValue == adjacent.path && viewer.macroEnvironment.fileName == adjacent.lastPathComponent, "Neighbor refreshes identity and filename context")
        viewer.editRequested()
        try require(editedURL == adjacent, "F6 after navigation targets the current neighbor")
        viewer.previousFileRequested(); viewer.cancelRequested(); try await settle()
        try require(viewer.sourceURL == adjacent && viewer.navigation?.currentIndex == 1, "Cancelled navigation preserves current file and index")
        viewer.previousFileRequested(); try await settle()
        try require(viewer.sourceURL == url && viewer.textView.string.contains("appended🙂"), "Previous neighbor restores original file")
        try Data("changed neighbor".utf8).write(to: adjacent)
        let previousText = viewer.textView.string
        viewer.nextFileRequested(); try await settle()
        try require(viewer.sourceURL == url && viewer.textView.string == previousText && viewer.navigation?.currentIndex == 0 && !viewer.message.stringValue.isEmpty, "Stale neighbor fails without switching document")
        return ["Viewer whole-word search controls", "Viewer cyclic search controls", "Viewer follows growing file", "Viewer search stops follow", "Viewer dump and F2/F4 modes", "Viewer captured panel neighbors", "Viewer cancelled navigation preserves file", "Viewer stale neighbor preserves file"]
    }
}
