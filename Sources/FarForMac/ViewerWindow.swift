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

    F2 — перенос в тексте или выход из дампа, Shift+F2 — перенос по словам или символам. F4 — hex и обратно, Shift+F4 — выбор текста / hex / дампа. F6 — открыть редактор в текущей позиции. F7 или Cmd+F — диалог поиска, Shift+F7 или пробел — далее, Option+F7 — назад. F8 — ANSI / OEM, Shift+F8 — выбор кодовой страницы. Option+F8 — диалог перехода. Home / End — начало / конец файла, Page Up / Down — прокрутка с переходом к соседнему блоку на границе. F10 — закрыть окно. Кнопки «Назад» / «Далее» читают соседние блоки. «Предыдущий файл» / «Следующий файл» и цифровые − / + открывают соседний обычный файл в порядке панели. Esc отменяет текущую операцию или закрывает окно.

    Просмотр читает блоки до 64 КиБ. Hex показывает точные байты, адрес и символы выбранной кодировки. Alt+←/→ меняет число байтов на строку по одному, Ctrl+Alt+←/→ — по сетке с шагом 16. Ctrl+←/→ сдвигает начало строки на байт в hex или на одну кодовую единицу в дампе. Дамп использует ширину видимой области. В UTF-8 байты продолжения показаны как ›. В UTF-16 пара суррогатов отображается символом и ›. Переводы строк и Tab показаны видимыми знаками. Ширина широких глифов зависит от шрифта AppKit. F4 возвращает последний основной режим: текст или дамп. BOM и действующая кодировка показаны рядом с выбором.

    Переход принимает десятичные байты, 0xFF, $FF, FFh, проценты и относительные значения со знаком. В тексте без переноса можно задать первую видимую колонку после запятой или пробела. Пустая координата сохраняет позицию.

    Поиск: текст, регулярное выражение по отдельным строкам или hex-байты. Направление и регистр задаются явно. «Нестрогий поиск» в режиме «Текст» раскрывает лигатуры, совместимые формы и цифры Unicode и игнорирует неалфавитные диакритические знаки; регистр задаётся независимо. Границы и выделение остаются в исходном тексте, включая удаляемые комбинируемые знаки. Regex и Hex с этим флажком дают явный отказ. Настройки запоминаются, история хранит 20 запросов вместе с флажками. Контекст нестрогого поиска ограничен 262144 единицами UTF-16; слишком длинная цепочка комбинируемых знаков даёт явную ошибку неполного поиска. «Целые слова» учитывают буквы, цифры, подчёркивание и комбинируемые знаки Unicode; для hex этот флажок не применяется. «Искать по кругу» продолжает поиск с другой границы файла; без флажка поиск останавливается у границы. Регулярные выражения ограничены строкой до 1 МиБ и временем проверки; превышение ограничений выдаёт ошибку, а не «не найдено». Длинное совпадение выделяется только в пределах показанного блока. Пустое совпадение при повторном поиске продвигает позицию на один Unicode-символ.

    End и «Следить за файлом» обновляют конец локального файла раз в секунду, включая усечение и замену файла. Поиск и переход в другую область останавливают слежение.

    Ctrl+Shift+0…9 или правый Ctrl+0…9 — установить закладку, левый Ctrl+0…9 — перейти. Ctrl+Z или Option+Backspace восстанавливает прежнее положение. Позиция, режим, кодировка, перенос и закладки сохраняются для 100 файлов. Замена или изменение файла сбрасывает позиции и закладки.
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
    private struct Bookmark: Codable, Equatable {
        var offset: Int64
        var title: String
        var column: Int? = nil
    }
    private struct History: Codable {
        var url: String
        var identity: String
        var offset: Int64 = 0
        var encoding: ViewerEncoding = .automatic
        var hex: Bool = false
        var dump: Bool? = nil
        var baseDump: Bool? = nil
        var wrap: Bool = true
        var wordWrap: Bool? = nil
        var bookmarks: [Bookmark] = []
        var numberedBookmarks: [Int: Bookmark]? = nil
        var accessed: Date = Date()
    }
    private enum RenderLayout: Equatable, Sendable {
        case text
        case dump(columns: Int)
        case hex(bytesPerRow: Int)
    }

    private struct Loaded: Sendable {
        let document: ViewerDocument
        let layout: RenderLayout
        let page: ViewerPage?
        let hexPage: ViewerHexPage?
        let logicalOffset: Int64
        let offset: Int64
        let selection: Range<Int64>?
    }

    private var sourceURL: URL
    private var navigation: ViewerNavigation?
    var currentNavigation: ViewerNavigation? { navigation }
    private let suppliedSource: (any ViewerByteSource)?
    private let onEdit: (URL, Int64, ViewerEncoding) -> Bool
    private let initialOffset: Int64?
    private let initialEncoding: ViewerEncoding
    private let initialDisplayMode: ViewerDisplayMode?
    private var viewerDocument: ViewerDocument?
    private var page: ViewerPage?
    private var hexPage: ViewerHexPage?
    private var hexBytesPerRow = ViewerHexLayout.defaultBytesPerRow
    private var displayedLayout: RenderLayout?
    private var displayOffset: Int64 = 0
    private var displayEnd: Int64 = 0
    private(set) var currentByteOffset: Int64 = 0
    private var identity: String?
    private var isHex = false
    private var isDump = false
    private var baseMode: ViewerDisplayMode = .text
    private var wraps = true
    private var wordWrap = true
    private var gotoHex: Bool?
    private var undoPosition: Bookmark?
    private var sessionBookmarks: [Int: Bookmark] = [:]
    private var requestedEncoding: ViewerEncoding = .automatic
    private var generation = UUID()
    private var cancellation: ViewerCancellation?
    private var busyTitle = ""
    private var closed = false
    private var presenting = false
    private var revealingEnd = false
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
    private var searchAccessory: NSStackView?
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

    convenience init(url: URL, initialByteOffset: Int64? = nil, initialEncoding: ViewerEncoding = .automatic, initialDisplayMode: ViewerDisplayMode? = nil,
                     navigation: ViewerNavigation? = nil, useRememberedEncoding: Bool = true, allowsEdit: Bool = true, customTitle: String? = nil,
                     onEdit: @escaping (URL, Int64, ViewerEncoding) -> Bool) throws {
        self.init(source: nil, url: url, initialByteOffset: initialByteOffset, initialEncoding: initialEncoding, initialDisplayMode: initialDisplayMode,
                  navigation: navigation, useRememberedEncoding: useRememberedEncoding, allowsEdit: allowsEdit, customTitle: customTitle, onEdit: onEdit)
    }

    convenience init(source: any ViewerByteSource, url: URL, initialByteOffset: Int64? = nil, initialEncoding: ViewerEncoding = .automatic,
                     initialDisplayMode: ViewerDisplayMode? = nil,
                     onEdit: @escaping (URL, Int64, ViewerEncoding) -> Bool) throws {
        self.init(source: Optional(source), url: url, initialByteOffset: initialByteOffset, initialEncoding: initialEncoding, initialDisplayMode: initialDisplayMode, navigation: nil, onEdit: onEdit)
    }

    private let useRememberedEncoding: Bool
    private let allowsEdit: Bool
    private let customTitle: String?
    private var luaReadSent = false
    private(set) var luaDidSwitchToEditor = false

    private init(source: (any ViewerByteSource)?, url: URL, initialByteOffset: Int64?, initialEncoding: ViewerEncoding, initialDisplayMode: ViewerDisplayMode?,
                 navigation: ViewerNavigation?, useRememberedEncoding: Bool = true, allowsEdit: Bool = true, customTitle: String? = nil,
                 onEdit: @escaping (URL, Int64, ViewerEncoding) -> Bool) {
        sourceURL = url.standardizedFileURL
        suppliedSource = source
        if source == nil, let navigation, navigation.urls[navigation.currentIndex] == url.standardizedFileURL {
            self.navigation = navigation
        }
        initialOffset = initialByteOffset
        self.initialEncoding = initialEncoding
        self.initialDisplayMode = initialDisplayMode
        self.useRememberedEncoding = useRememberedEncoding
        self.allowsEdit = allowsEdit
        self.customTitle = customTitle
        self.onEdit = onEdit
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = customTitle ?? "\(sourceURL.lastPathComponent) — Просмотр"
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
        followButton.isHidden = !canFollow
        if followButton.isHidden { navigation = nil }
        refreshFileButtons()
        if let view = window?.contentView { UIAccessibility.apply(to: view) }
        retainedWhileOpen = self
        super.showWindow(sender)
        window?.makeFirstResponder(textView)
        sendLuaReadIfReady()
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
        let fileNavigation = row([previousFileButton, nextFileButton, followButton])
        let edit = button("Редактор · F6", #selector(editRequested))
        edit.isHidden = !allowsEdit
        let formats = row([mode, encoding, wrapButton, effectiveEncoding, edit])
        cancelButton.target = self; cancelButton.action = #selector(cancelRequested)
        cancelButton.isEnabled = false
        let navigation = row([button("Начало", #selector(pageRequested), tag: -2),
                              button("Назад", #selector(pageRequested), tag: -1),
                              button("Далее", #selector(pageRequested), tag: 1),
                              button("Конец", #selector(pageRequested), tag: 2),
                              button("Перейти · Alt+F8", #selector(goRequested)), cancelButton])
        searchField.placeholderString = "Текст или шестнадцатеричные байты"
        searchField.cell?.sendsActionOnEndEditing = false
        searchField.setAccessibilityLabel("Строка поиска")
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        searchMode.addItems(withTitles: ["Текст", "Regex", "Hex"])
        searchDirection.addItems(withTitles: ["Вперёд", "Назад"])
        searchHistoryMenu.addItem(withTitle: "История поиска")
        searchHistoryMenu.target = self; searchHistoryMenu.action = #selector(searchHistorySelected)
        searchHistoryMenu.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let searching = row([button("Поиск · F7", #selector(showSearchDialog)),
                             button("Следующее", #selector(nextRequested)), button("Предыдущее", #selector(previousRequested))])
        searchAccessory = TextDocumentDialogs.accessory([
            row([searchField, searchMode]), searchHistoryMenu,
            row([caseButton, wordsButton]), row([fuzzyButton, cycleButton])
        ], height: 128, width: 465)
        fuzzyButton.toolTip = "Только текст: игнорировать диакритику, раскрывать лигатуры и совместимые Unicode-формы. Регистр задаётся отдельно."
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
        let stack = NSStackView(views: [path, formats, fileNavigation, navigation, searching, bookmarks, scroll, message, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        for view in [path, formats, fileNavigation, navigation, searching, bookmarks, scroll, message, footer] {
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
        operationControls = [formats, navigation, searching, bookmarks].flatMap { $0.arrangedSubviews.compactMap { $0 as? NSControl } }.filter { $0 !== cancelButton && $0 !== wrapButton }
        operationControls.append(followButton)
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
            let saved = self.canFollow ? Self.readHistory().first { $0.url == self.sourceURL.absoluteString } : nil
            if let saved {
                if self.useRememberedEncoding { self.requestedEncoding = saved.encoding }
                self.isHex = saved.hex; self.isDump = saved.dump == true && !saved.hex
                self.baseMode = (saved.baseDump ?? saved.dump) == true ? .dump : .text; self.wraps = saved.wrap
                self.wordWrap = saved.wordWrap ?? true
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
        let requested = requestedEncoding, layout = renderLayout
        work("Чтение блока", operation: { token, _ in
            let document = try ViewerDocument(source: source, encoding: requested)
            if token.isCancelled { throw ViewerError.cancelled }
            return try Self.load(document, at: offset, layout: layout)
        }) { [weak self] loaded in self?.present(loaded) }
    }

    private nonisolated static func load(_ document: ViewerDocument, at offset: Int64, layout: RenderLayout,
                                         selection: Range<Int64>? = nil) throws -> Loaded {
        let bounded = min(max(0, offset), document.size)
        let budget = document.size - bounded > Int64(pageSize) ? fullBlockByteCount(layout, encoding: document.encoding) : pageSize
        switch layout {
        case .hex(let bytesPerRow):
            let page = try document.hexPage(at: bounded, byteCount: budget, bytesPerRow: bytesPerRow)
            return Loaded(document: document, layout: layout, page: nil, hexPage: page, logicalOffset: bounded, offset: page.startOffset, selection: selection)
        case .dump(let columns):
            let page = try document.dumpPage(at: bounded, byteCount: budget, columns: columns)
            return Loaded(document: document, layout: layout, page: page, hexPage: nil, logicalOffset: page.startOffset, offset: page.startOffset, selection: selection)
        case .text:
            let page = try document.page(at: bounded)
            return Loaded(document: document, layout: layout, page: page, hexPage: nil, logicalOffset: page.startOffset, offset: page.startOffset, selection: selection)
        }
    }

    private nonisolated static func fullBlockByteCount(_ layout: RenderLayout, encoding: ViewerEncoding) -> Int {
        let rowBytes: Int
        switch layout {
        case .hex(let bytesPerRow): rowBytes = bytesPerRow
        case .dump(let columns): rowBytes = columns * (encoding == .utf16LE || encoding == .utf16BE ? 2 : 1)
        case .text: return pageSize
        }
        return pageSize / rowBytes * rowBytes
    }

    private func previousBlockOffset(in document: ViewerDocument) -> Int64 {
        let budget = Self.fullBlockByteCount(displayedLayout ?? renderLayout, encoding: document.encoding)
        return max(0, displayOffset - Int64(budget))
    }

    private func loadPage(at offset: Int64, selection: Range<Int64>? = nil, scrollToEnd: Bool = false,
                          column: Int? = nil, followEnd: Bool = false, layout requestedLayout: RenderLayout? = nil,
                          revealSelection: Bool = true) {
        guard let document = viewerDocument else { return }
        let layout = requestedLayout ?? renderLayout
        work("Чтение блока", operation: { token, _ in
            if token.isCancelled { throw ViewerError.cancelled }
            return try Self.load(document, at: offset, layout: layout, selection: selection)
        }) { [weak self] loaded in
            guard let self else { return }
            self.present(loaded, revealSelection: revealSelection)
            if scrollToEnd { self.revealEnd() }
            if let column { self.scrollToColumn(column) }
            if followEnd && self.canFollow { self.startFollowing() }
        }
    }

    private var isAtEnd: Bool {
        scroll.documentVisibleRect.maxY >= textView.bounds.maxY - 1
    }

    private func revealEnd() {
        revealingEnd = true
        defer { revealingEnd = false; scrolled() }
        if let container = textView.textContainer { textView.layoutManager?.ensureLayout(for: container) }
        textView.scrollRangeToVisible(NSRange(location: textView.string.utf16.count, length: 0))
        moveViewport(to: NSPoint(x: 0, y: max(0, textView.bounds.height - scroll.contentView.bounds.height)))
    }

    private func moveViewport(to point: NSPoint) {
        let clip = scroll.contentView
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: point, size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }

    private var columnWidth: CGFloat { (" " as NSString).size(withAttributes: [.font: textView.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]).width }
    private var visibleColumn: Int { max(0, Int(scroll.documentVisibleRect.minX / columnWidth)) }

    private var viewportColumns: Int {
        let inset = textView.textContainerInset.width + (textView.textContainer?.lineFragmentPadding ?? 0)
        let overlay = scroll.hasVerticalScroller && scroll.scrollerStyle == .overlay ? 1 : 0
        return min(1_000, max(1, Int(max(0, scroll.contentSize.width - 2 * inset) / columnWidth) - overlay))
    }

    private var renderLayout: RenderLayout {
        if isHex { return .hex(bytesPerRow: hexBytesPerRow) }
        if isDump { return .dump(columns: viewportColumns) }
        return .text
    }

    private func reflowDumpIfNeeded() {
        guard !closed, cancellation == nil, isDump, case .dump? = displayedLayout, displayedLayout != renderLayout,
              let document = viewerDocument else { return }
        let anchored = followTimer != nil || displayEnd == document.size && isAtEnd && scroll.documentVisibleRect.minY > 1
        let offset = anchored ? max(0, document.size - Int64(Self.pageSize - 16)) : visibleByteOffset()
        loadPage(at: offset, selection: anchored ? nil : lastMatch, scrollToEnd: anchored,
                 followEnd: followTimer != nil, revealSelection: false)
    }

    func windowDidResize(_ notification: Notification) { reflowDumpIfNeeded() }

    private func scrollToColumn(_ column: Int) {
        let clip = scroll.contentView
        let maxX = max(0, textView.bounds.width - clip.bounds.width)
        moveViewport(to: NSPoint(x: min(maxX, CGFloat(column) * columnWidth), y: clip.bounds.minY))
    }

    private func present(_ loaded: Loaded, revealSelection: Bool = true) {
        presenting = true
        viewerDocument = loaded.document
        sendLuaReadIfReady()
        operationControls.forEach { $0.isEnabled = true }
        page = loaded.page; hexPage = loaded.hexPage; displayedLayout = loaded.layout
        if let hexPage { hexBytesPerRow = hexPage.bytesPerRow }
        displayOffset = loaded.offset
        displayEnd = loaded.page?.endOffset ?? loaded.hexPage?.endOffset ?? loaded.offset
        currentByteOffset = loaded.logicalOffset
        textView.string = loaded.page?.text ?? loaded.hexPage?.text ?? ""
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        let match = loaded.selection.flatMap { match -> Range<Int64>? in
            if match.isEmpty { return (displayOffset...displayEnd).contains(match.lowerBound) ? match : nil }
            let lower = max(displayOffset, match.lowerBound)
            let upper = min(displayEnd, match.upperBound)
            return lower < upper ? lower..<upper : nil
        }
        if let match, let range = loaded.page?.utf16Range(forByteRange: match) ?? loaded.hexPage?.utf16Range(forByteRange: match) {
            textView.setSelectedRange(range)
            if revealSelection {
                currentByteOffset = match.lowerBound
                textView.scrollRangeToVisible(range)
            }
        }
        effectiveEncoding.stringValue = "\(loaded.document.encoding.title) · BOM: \(loaded.document.bomLength) байт"
        message.stringValue = loaded.page?.invalidSequences == true ? "Недопустимые последовательности заменены на �. Можно выбрать другую кодировку или Hex." : ""
        if let match, let selection = loaded.selection, match != selection {
            message.stringValue = "Совпадение: \(selection.lowerBound)..<\(selection.upperBound). Выделена его часть в показанном блоке."
        }
        presenting = false
        window?.makeFirstResponder(textView)
        refreshStatus(); refreshHistoryMenus()
        if isDump, loaded.layout != renderLayout {
            DispatchQueue.main.async { [weak self] in self?.reflowDumpIfNeeded() }
        }
    }

    private func sendLuaReadIfReady() {
        guard !luaReadSent, viewerDocument != nil, let window, window.isVisible else { return }
        luaReadSent = true
        FarLuaWorkspace.shared.event("ViewerEvent", [.hostInteger(window.windowNumber), .integer(0), .nilValue])
    }

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
        let width: String
        switch displayedLayout {
        case .hex(let bytesPerRow)?: width = " · \(bytesPerRow) байт/строка"
        case .dump(let columns)?: width = " · \(columns) колонок"
        default: width = ""
        }
        let base = "Байт \(currentByteOffset) / \(size) · \(String(format: "%.2f", percent))% · блок \(displayOffset)..<\(displayEnd)\(width)"
        status.stringValue = busyTitle.isEmpty ? base : "\(busyTitle)…\(progress.map { " \($0) байт" } ?? "") · Esc — отменить"
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !presenting, viewerDocument != nil else { return }
        currentByteOffset = offsetForCharacter(textView.selectedRange().location)
        refreshStatus()
    }

    private func offsetForCharacter(_ index: Int) -> Int64 {
        page?.byteOffset(forUTF16: index) ?? hexPage?.byteOffset(forUTF16: index) ?? displayOffset
    }

    private func visibleByteOffset(bottom: Bool = false) -> Int64 {
        guard !presenting, viewerDocument != nil, let container = textView.textContainer,
              let layout = textView.layoutManager, layout.numberOfGlyphs > 0 else { return displayOffset }
        if bottom && isAtEnd { return displayEnd }
        if bottom {
            let visible = scroll.documentVisibleRect
            let rect = NSRect(x: 0, y: max(0, visible.minY - textView.textContainerInset.height),
                              width: max(visible.width, textView.bounds.width), height: visible.height)
            let end = NSMaxRange(layout.glyphRange(forBoundingRect: rect, in: container))
            return end >= layout.numberOfGlyphs ? displayEnd : offsetForCharacter(layout.characterIndexForGlyph(at: end))
        }
        var point = scroll.contentView.bounds.origin
        point.x = 0
        point.y = max(0, point.y - textView.textContainerInset.height)
        let glyph = layout.glyphIndex(for: point, in: container)
        let character = layout.characterIndexForGlyph(at: min(glyph, max(0, layout.numberOfGlyphs - 1)))
        return offsetForCharacter(character)
    }

    private func scrolled() {
        guard !presenting, viewerDocument != nil else { return }
        if followButton.state == .on && !revealingEnd && !isAtEnd { stopFollowing() }
        currentByteOffset = visibleByteOffset(); refreshStatus()
    }

    @objc private func pageRequested(_ sender: NSButton) {
        stopFollowing()
        guard let document = viewerDocument, cancellation == nil else { return }
        rememberPosition()
        lastMatch = nil
        switch sender.tag {
        case -2: loadPage(at: 0)
        case -1: loadPage(at: previousBlockOffset(in: document))
        case 2: loadPage(at: max(0, document.size - Int64(Self.pageSize - 16)), scrollToEnd: true, followEnd: true)
        default: if displayEnd < document.size { loadPage(at: displayEnd) }
        }
    }

    @objc private func encodingChanged() {
        changeEncoding(ViewerEncoding.allCases[encoding.indexOfSelectedItem])
    }

    private func changeEncoding(_ selected: ViewerEncoding) {
        guard let source = viewerDocument?.source, cancellation == nil else { return }
        stopFollowing()
        let offset = currentByteOffset, layout = renderLayout
        lastMatch = nil
        encoding.selectItem(at: ViewerEncoding.allCases.firstIndex(of: requestedEncoding) ?? 0)
        work("Смена кодовой страницы", operation: { token, _ in
            let document = try ViewerDocument(source: source, encoding: selected)
            if token.isCancelled { throw ViewerError.cancelled }
            return try Self.load(document, at: offset, layout: layout)
        }) { [weak self] loaded in
            guard let self else { return }
            self.requestedEncoding = selected
            self.encoding.selectItem(at: ViewerEncoding.allCases.firstIndex(of: selected) ?? 0)
            self.updateHistory { $0.encoding = selected }
            self.present(loaded)
        }
    }

    @objc private func modeChanged() { applyMode(updateBase: true) }

    private func applyMode(updateBase: Bool) {
        let hex = mode.indexOfSelectedItem == 1, dump = mode.indexOfSelectedItem == 2
        guard hex != isHex || dump != isDump else { return }
        stopFollowing()
        isHex = hex; isDump = dump
        if updateBase && !isHex { baseMode = isDump ? .dump : .text }
        let baseDump = baseMode == .dump
        updateHistory { $0.hex = hex; $0.dump = dump; $0.baseDump = baseDump }
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

    private func toggleWrapType() {
        guard !isHex, !isDump else { return }
        wordWrap.toggle()
        let selected = wordWrap
        updateHistory { $0.wordWrap = selected }
        updateWrap()
    }

    private func refreshFileButtons() {
        let available = canFollow
        previousFileButton.isHidden = !available || navigation == nil
        nextFileButton.isHidden = previousFileButton.isHidden
        previousFileButton.isEnabled = available && cancellation == nil && navigation?.adjacentIndex(forward: false) != nil
        nextFileButton.isEnabled = available && cancellation == nil && navigation?.adjacentIndex(forward: true) != nil
    }

    @objc private func previousFileRequested() { navigateFile(forward: false) }
    @objc private func nextFileRequested() { navigateFile(forward: true) }

    private func navigateFile(forward: Bool) {
        guard cancellation == nil, canFollow,
              let navigation, let index = navigation.adjacentIndex(forward: forward) else { return }
        stopFollowing()
        let target = navigation.urls[index]
        let saved = Self.readHistory().first { $0.url == target.absoluteString }
        let requested = saved?.encoding ?? requestedEncoding, hex = isHex, dump = isDump, layout = renderLayout
        let baseDump = baseMode == .dump
        work("Открытие соседнего файла", operation: { token, _ in
            let source = try navigation.source(at: index, cancellation: token)
            let document = try ViewerDocument(source: source, encoding: requested)
            let offset = saved?.identity == source.identity ? saved?.offset ?? 0 : 0
            let loaded = try Self.load(document, at: offset, layout: layout)
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
            self.window?.title = self.customTitle ?? "\(target.lastPathComponent) — Просмотр"; self.window?.representedURL = target
            self.lastMatch = nil; self.lastSearchSignature = nil
            self.undoPosition = nil; self.sessionBookmarks = [:]
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
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = wordWrap ? .byWordWrapping : .byCharWrapping
        textView.defaultParagraphStyle = paragraph
        if let storage = textView.textStorage {
            storage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: storage.length))
        }
        textView.isHorizontallyResizable = !wrap
        textView.autoresizingMask = wrap ? [.width] : []
        textView.textContainer?.widthTracksTextView = wrap
        textView.textContainer?.containerSize = NSSize(width: wrap ? max(100, scroll.contentSize.width - 24) : .greatestFiniteMagnitude,
                                                     height: .greatestFiniteMagnitude)
        if wrap { textView.setFrameSize(NSSize(width: max(100, scroll.contentSize.width), height: textView.frame.height)) }
    }

    @objc private func goRequested() {
        guard cancellation == nil, let document = viewerDocument else { return }
        let column = !wraps && !isDump && !isHex ? visibleColumn : nil
        let value = NSTextField(string: "")
        value.placeholderString = column == nil ? "Смещение" : "Смещение, колонка"
        value.widthAnchor.constraint(equalToConstant: 375).isActive = true
        value.setAccessibilityLabel("Смещение")
        let hex = NSButton(checkboxWithTitle: "Шестнадцатеричные значения", target: nil, action: nil)
        hex.state = (gotoHex ?? isHex) ? .on : .off
        let alert = NSAlert()
        alert.messageText = "Перейти к позиции"
        alert.informativeText = "Например: $20, 20h, 32m, 50% или +16."
        alert.accessoryView = TextDocumentDialogs.accessory([value, hex], height: 60)
        alert.addButton(withTitle: "Перейти")
        alert.addButton(withTitle: "Отмена").keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = value
        while alert.runModal() == .alertFirstButtonReturn {
            do {
                let hexadecimal = hex.state == .on
                let target = try ViewerGotoPosition(value.stringValue, hexadecimal: hexadecimal,
                    offset: currentByteOffset, fileSize: document.size, visibleColumn: column)
                gotoHex = hexadecimal
                stopFollowing(); rememberPosition(); lastMatch = nil
                if target.offset == document.size {
                    loadPage(at: max(0, document.size - Int64(Self.pageSize - 16)), scrollToEnd: true,
                             column: target.column ?? column, followEnd: true)
                } else if target.offset == currentByteOffset {
                    if let column = target.column { scrollToColumn(column) }
                } else { loadPage(at: target.offset, column: target.column ?? column) }
                return
            } catch { alert.informativeText = error.localizedDescription }
        }
    }

    private var canFollow: Bool {
        suppliedSource == nil && retainedArchiveWorkspace == nil && retainedRemoteWorkspace == nil && retainedRemoteLease == nil
    }

    @objc private func followChanged() {
        if followButton.state != .on || !canFollow { stopFollowing(); return }
        startFollowing()
        pollFollow(force: true)
    }

    private func startFollowing() {
        followButton.state = .on
        followRevision = UUID()
        followTimer?.invalidate()
        followTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollFollow() }
        }
    }

    private func stopFollowing() {
        followTimer?.invalidate(); followTimer = nil; followButton.state = .off; followRevision = UUID()
    }

    private func pollFollow(force: Bool = false) {
        guard !closed, followButton.state == .on, !followPending, cancellation == nil else { return }
        followPending = true
        let revision = followRevision, operation = generation
        let url = sourceURL, previous = force ? nil : viewerDocument?.source.identity
        let requested = requestedEncoding, layout = renderLayout
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result: Result<Loaded?, Error> = Result {
                guard let update = try ViewerTail.poll(url: url, previousIdentity: previous, encoding: requested) else { return nil }
                return try Self.load(update.document, at: update.offset, layout: layout)
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
                    self.revealEnd()
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

    @objc private func showSearchDialog() {
        guard cancellation == nil, viewerDocument != nil, let searchAccessory else { return }
        let previous = searchSettings
        let alert = NSAlert()
        alert.messageText = "Поиск в файле"
        alert.accessoryView = searchAccessory
        defer { alert.accessoryView = nil }
        alert.addButton(withTitle: "Найти далее")
        alert.addButton(withTitle: "Найти назад")
        alert.addButton(withTitle: "Отмена").keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = searchField
        UIAccessibility.apply(to: searchAccessory)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else {
            let match = lastMatch, signature = lastSearchSignature
            applySearchSettings(previous); lastMatch = match; lastSearchSignature = signature
            return
        }
        searchDirection.selectItem(at: response == .alertSecondButtonReturn ? 1 : 0)
        searchRequested()
    }

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
        let current = visibleByteOffset(bottom: direction == .backward), layout = renderLayout
        lastSearchSignature = signature
        work("Поиск", operation: { token, progress in
            try ViewerSearch.validate(query)
            var from = current
            if let previous {
                if direction == .backward { from = previous.lowerBound }
                else if previous.lowerBound >= document.size {
                    if !cycle { return Optional<Loaded>.none }
                    from = 0
                } else if query.mode == .hex { from = previous.lowerBound + 1 }
                else {
                    let page = try document.page(at: previous.lowerBound, byteCount: 4)
                    let width = page.text.unicodeScalars.first.map { $0.value > 0xFFFF ? 2 : 1 } ?? 1
                    from = max(previous.lowerBound + 1, page.byteOffset(forUTF16: width))
                }
            }
            guard let found = try ViewerSearch.find(document: document, query: query, from: from,
                                                    direction: direction, wrap: cycle, cancellation: token, onProgress: progress) else { return Optional<Loaded>.none }
            return try Optional(Self.load(document, at: found.byteRange.lowerBound, layout: layout, selection: found.byteRange))
        }) { [weak self] loaded in
            guard let self else { return }
            guard let loaded else { self.message.stringValue = cycle ? "Совпадений нет во всём файле." : "Совпадение не найдено до \(direction == .forward ? "конца" : "начала") файла. Поиск без перехода через границу."; return }
            self.rememberPosition()
            self.lastMatch = loaded.selection; self.present(loaded)
        }
    }

    @objc private func editRequested() {
        guard allowsEdit else { return }
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
        if onEdit(sourceURL, offset, document.encoding) {
            luaDidSwitchToEditor = true
            window?.close()
        }
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

    @objc private func searchHistorySelected() {
        guard let index = searchHistoryMenu.selectedItem?.representedObject as? Int else { return }
        let entries = Self.readSearchHistory(); guard entries.indices.contains(index) else { return }
        applySearchSettings(entries[index]); searchHistoryMenu.selectItem(at: 0)
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
                if FarLuaWorkspace.shared.handle(event) { return true }
                if CommandWorkspace.shared.handle(event) { return true }
                return self.handleKey(event)
            }
            return consumed ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if let bookmark = TextDocumentDialogs.bookmarkShortcut(event, flags: flags) {
            if bookmark.set { setBookmark(bookmark.slot) }
            else { gotoBookmark(bookmark.slot) }
            return true
        }
        switch (event.keyCode, flags) {
        case (3, .command), (98, []): showSearchDialog()
        case (53, []), (99, []), (109, []), (87, []):
            if cancellation != nil { cancelRequested() } else { closeRequested() }
        case (103, []): FarLuaPlugins.shared.showMenu()
        case (122, []): showViewerHelp()
        case (120, []): f2Requested()
        case (120, .shift): if cancellation == nil { toggleWrapType() }
        case (118, []): if cancellation == nil { toggleHex() }
        case (118, .shift): if cancellation == nil { mode.performClick(nil) }
        case (97, []): editRequested()
        case (98, .shift), (49, []): if cancellation == nil { nextRequested() }
        case (98, .option): if cancellation == nil { previousRequested() }
        case (100, .option): goRequested()
        case (100, []):
            if let document = viewerDocument { changeEncoding(TextDocumentDialogs.nextCodePage(after: document.encoding)) }
        case (100, .shift):
            if cancellation == nil, let current = viewerDocument?.encoding, let selected = TextDocumentDialogs.codePage(current: current) {
                changeEncoding(selected)
            }
        case (69, []), (78, []): navigateFile(forward: event.keyCode == 69)
        case (115, []), (115, .control): pageRequested(NSButtonWithTag(-2))
        case (119, []), (119, .control): pageRequested(NSButtonWithTag(2))
        case (126, []), (125, []), (116, []), (121, []):
            guard window?.firstResponder === textView else { return false }
            let forward = event.keyCode == 125 || event.keyCode == 121
            scrollVertically(forward: forward, byPage: event.keyCode == 116 || event.keyCode == 121)
        case (123, .option), (124, .option), (123, [.control, .option]), (124, [.control, .option]):
            guard isHex else { return false }
            let step = flags.contains(.control) ? 16 : 1
            changeHexRowWidth(event.keyCode == 124 ? step : -step)
        case (123, .control) where isHex || isDump, (124, .control) where isHex || isDump:
            rollContents(event.keyCode == 124 ? 1 : -1)
        case (123, []), (124, []), (123, .control), (124, .control), (123, [.control, .shift]), (124, [.control, .shift]):
            guard window?.firstResponder === textView, isHex || !wraps && !isDump else { return false }
            let forward = event.keyCode == 124
            let step = flags == .control ? 20 : 1
            let target = flags.contains(.shift) ? (forward ? Int.max : 0) : max(0, visibleColumn + (forward ? step : -step))
            scrollToColumn(target)
        case (6, .control), (51, .option):
            if let position = undoPosition { restorePosition(position, remember: false); undoPosition = nil }
        case (8, .control), (114, .control): textView.copy(nil)
        case (32, .control): textView.setSelectedRange(NSRange(location: textView.selectedRange().location, length: 0))
        case (1, .control): scroll.hasVerticalScroller.toggle(); reflowDumpIfNeeded()
        default: return false
        }
        return true
    }

    private func changeHexRowWidth(_ step: Int) {
        guard cancellation == nil, let document = viewerDocument else { return }
        let width = ViewerHexLayout.adjustedBytesPerRow(hexBytesPerRow, by: step, columns: viewportColumns, encoding: document.encoding)
        guard width != hexBytesPerRow else { return }
        let anchored = followTimer != nil
        let offset = anchored ? max(0, document.size - Int64(Self.pageSize - 16)) : visibleByteOffset()
        loadPage(at: offset, selection: anchored ? nil : lastMatch, scrollToEnd: anchored,
                 column: visibleColumn, followEnd: anchored, layout: .hex(bytesPerRow: width), revealSelection: false)
    }

    private func rollContents(_ step: Int64) {
        guard cancellation == nil, let document = viewerDocument, document.size > 0 else { return }
        let unit: Int64 = isDump && (document.encoding == .utf16LE || document.encoding == .utf16BE) ? 2 : 1
        let offset = visibleByteOffset()
        let bounded = min(offset, document.size - 1)
        let shifted = step > 0 ? bounded + min(unit, document.size - 1 - bounded) : max(0, bounded - unit)
        let next = shifted / unit * unit
        guard next != offset else { return }
        stopFollowing(); rememberPosition(); lastMatch = nil
        loadPage(at: next, column: isHex ? visibleColumn : nil)
    }

    private func scrollVertically(forward: Bool, byPage: Bool) {
        guard cancellation == nil, let document = viewerDocument else { return }
        let clip = scroll.contentView
        let visible = scroll.documentVisibleRect
        if forward && isAtEnd && displayEnd < document.size {
            stopFollowing(); rememberPosition(); lastMatch = nil
            loadPage(at: displayEnd)
        } else if !forward && visible.minY <= 1 && displayOffset > 0 {
            stopFollowing(); rememberPosition(); lastMatch = nil
            loadPage(at: previousBlockOffset(in: document), scrollToEnd: true)
        } else {
            let lineHeight = textView.layoutManager?.defaultLineHeight(for: textView.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)) ?? 16
            let distance = byPage ? max(lineHeight, clip.bounds.height - lineHeight) : lineHeight
            if !forward { stopFollowing() }
            if forward && !isAtEnd || !forward && visible.minY > 1 { rememberPosition() }
            moveViewport(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + (forward ? distance : -distance)))
            if forward && isAtEnd && displayEnd == document.size && canFollow && followTimer == nil { startFollowing() }
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
        guard canFollow else { return }
        guard let identity else { return }
        var entries = Self.readHistory()
        let index = entries.firstIndex { $0.url == sourceURL.absoluteString }
        var entry = index.map { entries[$0] } ?? History(url: sourceURL.absoluteString, identity: identity)
        if entry.identity != identity {
            guard allowIdentityReset else { return }
            entry.identity = identity; entry.offset = 0; entry.bookmarks = []; entry.numberedBookmarks = nil
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
        let selectedSlot = bookmarkMenu.selectedItem?.tag
        let selectedOffset = bookmarkMenu.selectedItem?.representedObject as? Int64
        let numbered = canFollow ? saved?.numberedBookmarks ?? [:] : sessionBookmarks
        bookmarkMenu.removeAllItems(); bookmarkMenu.addItem(withTitle: "Закладки (\(numbered.count)/10)")
        for slot in numbered.keys.sorted() {
            guard let bookmark = numbered[slot] else { continue }
            bookmarkMenu.addItem(withTitle: "\(slot) — \(bookmark.title)")
            bookmarkMenu.lastItem?.tag = slot + 1
            if selectedSlot == slot + 1 { bookmarkMenu.select(bookmarkMenu.lastItem) }
        }
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
        guard let slot = (0...9).first(where: { numberedBookmarks[$0] == nil }) else {
            message.stringValue = "Все десять закладок заняты. Ctrl+Shift+цифра обновляет выбранную закладку."
            return
        }
        setBookmark(slot)
    }

    @objc private func removeBookmark() {
        if let slot = bookmarkMenu.selectedItem?.tag, slot > 0 {
            if canFollow { updateHistory { $0.numberedBookmarks?[slot - 1] = nil } }
            else { sessionBookmarks.removeValue(forKey: slot - 1); refreshHistoryMenus() }
            return
        }
        guard let offset = bookmarkMenu.selectedItem?.representedObject as? Int64 else { message.stringValue = "Выберите закладку для удаления."; return }
        updateHistory { $0.bookmarks.removeAll { $0.offset == offset } }
    }

    @objc private func bookmarkSelected() {
        if let slot = bookmarkMenu.selectedItem?.tag, slot > 0 { gotoBookmark(slot - 1); return }
        guard let offset = bookmarkMenu.selectedItem?.representedObject as? Int64 else { return }
        restorePosition(Bookmark(offset: offset, title: "Байт \(offset)"))
    }

    private var numberedBookmarks: [Int: Bookmark] {
        if !canFollow { return sessionBookmarks }
        return Self.readHistory().first { $0.url == sourceURL.absoluteString && $0.identity == identity }?.numberedBookmarks ?? [:]
    }

    private func setBookmark(_ slot: Int) {
        guard viewerDocument != nil, cancellation == nil else { return }
        let position = currentPosition
        if canFollow {
            updateHistory { entry in
                var bookmarks = entry.numberedBookmarks ?? [:]
                bookmarks[slot] = position
                entry.numberedBookmarks = bookmarks
            }
        } else { sessionBookmarks[slot] = position; refreshHistoryMenus() }
        message.stringValue = "Закладка \(slot) установлена."
    }

    private func gotoBookmark(_ slot: Int) {
        if let bookmark = numberedBookmarks[slot] { restorePosition(bookmark) }
        else { NSSound.beep() }
    }

    private var currentPosition: Bookmark {
        let offset = visibleByteOffset()
        return Bookmark(offset: offset, title: "Байт \(offset)", column: isHex || !wraps && !isDump ? visibleColumn : nil)
    }

    private func rememberPosition() { undoPosition = currentPosition }

    private func restorePosition(_ position: Bookmark, remember: Bool = true) {
        guard viewerDocument != nil, cancellation == nil else { return }
        stopFollowing()
        if remember { rememberPosition() }
        lastMatch = nil; loadPage(at: position.offset, column: position.column)
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
        if luaReadSent {
            FarLuaWorkspace.shared.event("ViewerEvent", [.hostInteger(window?.windowNumber ?? -1), .integer(1), .nilValue])
        }
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
    var luaDocumentIsClosed: Bool { closed }
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
        try require(restored.isHex && !restored.isDump && restored.currentByteOffset == 10 && restored.textView.string.hasPrefix("000000000A: "), "Explicit hex byte position overrides saved viewer text mode")
        restored.fuzzyButton.state = .off; restored.searchField.stringValue = "changed"
        restored.searchHistoryMenu.selectItem(at: 1); restored.searchHistorySelected()
        try require(restored.fuzzyButton.state == .on && restored.searchField.stringValue == "cafe", "Search history restores fuzzy and pattern together")
        let oldMatch = viewer.lastMatch
        viewer.searchMode.selectItem(at: 1); viewer.searchRequested()
        try require(viewer.cancellation == nil && viewer.lastMatch == oldMatch && viewer.message.stringValue.contains("только"), "Fuzzy plus regex reports unsupported mode without changing selection")
        let leaseURL = directory.appendingPathComponent("viewer-lease-\(UUID().uuidString).txt")
        try Data("temporary snapshot".utf8).write(to: leaseURL)
        let temporary = try ViewerWindow(url: leaseURL, onEdit: { _, _, _ in false })
        defer { temporary.window?.close(); try? FileManager.default.removeItem(at: leaseURL) }
        temporary.retainedRemoteLease = NSObject()
        temporary.showWindow(nil); try await settle(temporary)
        try require(temporary.followButton.isHidden && temporary.numberedBookmarks.isEmpty, "Temporary snapshot uses no local-file follow or saved bookmarks")
        temporary.window?.close()
        try require(!Self.readHistory().contains { $0.url == leaseURL.absoluteString }, "Temporary snapshot does not write the local viewer history")
        return ["Viewer fuzzy original byte highlights", "Viewer fuzzy next and wrap", "Viewer fuzzy settings and search history", "Viewer fuzzy rejects regex", "Viewer initial hex mode and byte offset override history", "Viewer temporary lease skips history"]
    }

    static func runViewerUISmokeChecks() async throws -> [String] {
        let directory = AppRuntime.smokeDirectory ?? FileManager.default.temporaryDirectory
        let url = directory.appendingPathComponent("viewer-options-smoke.txt")
        try Data(("cats cat\n" + String(repeating: "plain row\n", count: 500)).utf8).write(to: url)
        var editedURL: URL?
        let viewer = try ViewerWindow(url: url, onEdit: { url, _, _ in editedURL = url; return false })
        defer { viewer.window?.close(); try? FileManager.default.removeItem(at: url) }
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw NSError(domain: "ViewerSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func settle(_ controller: ViewerWindow? = nil) async throws {
            let target = controller ?? viewer
            let deadline = Date().addingTimeInterval(5)
            while (target.cancellation != nil || target.followPending) && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            try require(target.cancellation == nil && !target.followPending, "Viewer worker completes")
        }
        func press(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = []) throws {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: viewer.window?.windowNumber ?? 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
            try require(viewer.handleKey(event), "Viewer handles keyboard shortcut \(code)")
        }
        viewer.showWindow(nil); try await settle()
        let originalWrap = viewer.wordWrap
        try press(120, .shift)
        try require(viewer.wraps && viewer.wordWrap != originalWrap, "Shift F2 changes wrap type without turning wrapping off")
        try press(120, .shift)
        try press(18, [.control, .shift])
        try require(viewer.numberedBookmarks[1]?.offset == 0, "Ctrl Shift digit records a numbered viewer bookmark")
        try press(100); try await settle()
        try require(viewer.viewerDocument?.encoding == TextDocumentDialogs.systemCodePages[0], "F8 changes the viewer to ANSI")
        try press(100); try await settle()
        try require(viewer.viewerDocument?.encoding == TextDocumentDialogs.systemCodePages[1], "F8 cycles the viewer from ANSI to OEM")
        viewer.changeEncoding(.automatic); try await settle()
        viewer.applySearchSettings(SearchSettings(pattern: "cat", wholeWords: true))
        viewer.searchRequested(); try await settle()
        try require(viewer.lastMatch == 5..<8, "Viewer whole words select exact result")
        viewer.cycleButton.state = .on; viewer.nextRequested(); try await settle()
        viewer.nextRequested(); try await settle()
        try require(viewer.lastMatch == 5..<8, "Viewer cyclic search repeats after boundary")
        try press(119); try await settle()
        try require(viewer.isAtEnd && viewer.currentByteOffset > 0 && viewer.followTimer != nil,
                    "End scrolls a short file to the last viewport and arms tail follow")
        try press(18, .control); try await settle()
        try require(viewer.currentByteOffset == 0 && viewer.followTimer == nil, "Ctrl digit jumps back and stops tail follow")
        try press(119); try await settle()
        let handle = try FileHandle(forWritingTo: url); try handle.seekToEnd(); try handle.write(contentsOf: Data("appended🙂\n".utf8)); try handle.close()
        viewer.pollFollow(); try await settle()
        try require(viewer.textView.string.hasSuffix("appended🙂\n"), "Viewer follows growing local file")
        viewer.searchRequested(); try await settle()
        try require(viewer.followButton.state == .off && viewer.followTimer == nil, "Search stops viewer follow")
        viewer.mode.selectItem(at: 2); viewer.modeChanged(); try await settle()
        try require(viewer.isDump && viewer.textView.string.contains("␊") && viewer.textView.string.contains("›"), "Dump renders code units without interpreting source newlines")
        guard let window = viewer.window, case .dump(let oldColumns)? = viewer.displayedLayout else {
            throw NSError(domain: "ViewerSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "Viewer dump must have a viewport layout"])
        }
        let frame = window.contentLayoutRect
        window.setContentSize(NSSize(width: frame.width + 120, height: frame.height))
        window.contentView?.layoutSubtreeIfNeeded()
        viewer.reflowDumpIfNeeded(); try await settle()
        try require(viewer.displayedLayout == .dump(columns: viewer.viewportColumns) && viewer.viewportColumns > oldColumns,
                    "Wider window shows more dump cells on each row")
        viewer.toggleHex(); try await settle()
        try require(viewer.isHex && viewer.textView.string.hasPrefix(String(format: "%010llX: ", viewer.displayOffset)), "F4 switches dump to hex")
        try require(viewer.textView.string.contains("🙂") && viewer.textView.string.contains("›"), "Hex side column decodes Unicode and preserves continuation bytes")
        let hexOffset = viewer.displayOffset
        try press(124, .control); try await settle()
        try require(viewer.displayOffset == hexOffset + 1, "Ctrl Right rolls hex rows by one byte")
        try press(123, .control); try await settle()
        try require(viewer.displayOffset == hexOffset, "Ctrl Left rolls hex rows back")
        try press(124, .option); try await settle()
        try require(viewer.hexPage?.bytesPerRow == 17 && viewer.displayOffset == hexOffset, "Alt Right widens hex rows while keeping byte position")
        try press(123, [.control, .option]); try await settle()
        try require(viewer.hexPage?.bytesPerRow == 16, "Ctrl Alt Left returns to the previous 16-byte grid point")
        viewer.toggleHex(); try await settle()
        try require(viewer.isDump && !viewer.isHex, "F4 returns to dump base mode")
        viewer.f2Requested(); try await settle()
        try require(!viewer.isHex && !viewer.isDump && viewer.baseMode == .dump, "F2 switches dump to text while keeping dump as the base")
        viewer.mode.selectItem(at: 0); viewer.modeChanged()
        try require(viewer.baseMode == .dump, "Selecting the active mode leaves the base unchanged")
        viewer.toggleHex(); try await settle(); viewer.toggleHex(); try await settle()
        try require(viewer.isDump && !viewer.isHex, "F4 still returns to dump after reselecting active text mode")
        viewer.mode.selectItem(at: 0); viewer.modeChanged(); try await settle()
        try require(!viewer.isHex && !viewer.isDump && viewer.baseMode == .text, "Selecting a different text mode makes it the base")
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

        let largeURL = directory.appendingPathComponent("viewer-formatted-block-\(UUID().uuidString).bin")
        try Data(repeating: 0x41, count: 140_000).write(to: largeURL)
        let large = try ViewerWindow(url: largeURL, initialDisplayMode: .hex, onEdit: { _, _, _ in false })
        defer { large.window?.close(); try? FileManager.default.removeItem(at: largeURL) }
        large.showWindow(nil); try await settle(large)
        large.changeHexRowWidth(1); try await settle(large)
        try require(large.hexPage?.bytesPerRow == 17 && large.displayEnd == 65_535, "Hex forward blocks end on complete rows")
        large.pageRequested(NSButtonWithTag(1)); try await settle(large)
        let secondOffset = large.displayOffset
        large.pageRequested(NSButtonWithTag(1)); try await settle(large)
        try require(large.displayOffset == 131_070, "Third hex block starts on the same 17-byte grid")
        large.pageRequested(NSButtonWithTag(-1)); try await settle(large)
        try require(large.displayOffset == secondOffset, "Moving backward restores the exact start of the previous formatted block")
        large.lastMatch = 10..<11
        large.changeHexRowWidth(1); try await settle(large)
        try require(large.displayOffset == secondOffset && large.currentByteOffset == secondOffset && large.textView.selectedRange().length == 0,
                    "Hex width change keeps its viewport and ignores a match outside the displayed block")
        return ["Viewer whole-word search controls", "Viewer cyclic search controls", "Viewer End anchors growing file", "Viewer numbered bookmark keyboard shortcuts", "Viewer Shift F2 wrap type", "Viewer F8 code-page cycling", "Viewer search stops follow", "Viewer dump resize and F2/F4 modes", "Viewer hex code page and width shortcuts", "Viewer captured panel neighbors", "Viewer cancelled navigation preserves file", "Viewer stale neighbor preserves file", "Viewer hex page grid round trip and selection bounds"]
    }
}

// LuaFar viewer positions are byte offsets (zero-based), unlike editor coordinates.
extension ViewerWindow {
    var sourceFileURL: URL { sourceURL }
    var luaViewerProperties: FarLuaValue {
        .table(["FileName": .string(sourceURL.path), "Selected": .bool(textView.selectedRange().length > 0), "State": .hostInteger((isHex ? 4 : 0) | (wraps ? 8 : 0) | (wordWrap ? 16 : 0))])
    }
    var luaViewerInfo: FarLuaValue {
        guard let document = viewerDocument else { return .nilValue }
        let cp: [ViewerEncoding: Int] = [.automatic: -1, .utf8:65001, .utf16LE:1200, .utf16BE:1201, .windows1251:1251, .windows1252:1252, .latin1:28591, .dos437:437, .dos866:866]
        return .table(["ViewerID": .hostInteger(window?.windowNumber ?? -1), "FileName": .string(sourceURL.path),
            "FileSize": .integer(document.size), "FilePos": .integer(currentByteOffset), "LeftPos": .hostInteger(visibleColumn + 1),
            "WindowSizeX": .hostInteger(Int(scroll.bounds.width / columnWidth)), "WindowSizeY": .hostInteger(Int(scroll.bounds.height / 16)),
            "Options": .integer(0), "TabSize": .integer(8),
            "CurMode": .table(["CodePage": .hostInteger(cp[document.encoding] ?? -1), "ViewMode": .integer(isHex ? 1 : isDump ? 2 : 0), "Flags": .integer((wraps ? 1 : 0) | (wordWrap ? 2 : 0))])])
    }
    func luaViewerCall(_ name: String, _ args: [FarLuaValue]) async throws -> [FarLuaValue] {
        guard !closed, args.lua(0).hostInt == nil || args.lua(0).hostInt == -1 || args.lua(0).hostInt == window?.windowNumber else { return [.nilValue] }
        let deadline = Date().addingTimeInterval(60)
        func awaitLoad() async throws {
            while cancellation != nil {
                try Task.checkCancellation()
                guard Date() < deadline else { throw ExtensionAPIError("Viewer: чтение не завершилось за 60 секунд") }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        try await awaitLoad()
        switch name {
        case "viewer.GetFileName": return [.string(sourceURL.path)]
        case "viewer.GetInfo": return [luaViewerInfo]
        case "viewer.Quit": window?.performClose(nil); return [.bool(closed)]
        case "viewer.Redraw": textView.needsDisplay = true; return []
        case "viewer.SetPosition":
            guard let document = viewerDocument else { return [.nilValue] }
            let props = args.lua(1).hostTable
            let raw = Int64(props["StartPos"]?.hostInt ?? args.lua(1).hostInt ?? 0)
            let flags = props["Flags"]?.hostInt ?? args.lua(3).hostInt ?? 0
            guard flags & ~15 == 0 else { throw ExtensionAPIError("viewer.SetPosition: неизвестные флаги") }
            var target = raw
            if flags & 2 != 0 { target = Int64(Double(document.size) * Double(min(100, max(0, raw))) / 100) }
            if flags & 4 != 0 {
                let addition = currentByteOffset.addingReportingOverflow(target)
                guard !addition.overflow else { return [.nilValue] }; target = addition.partialValue
            }
            target = min(document.size, max(0, target))
            let column = max(1, props["LeftPos"]?.hostInt ?? args.lua(2).hostInt ?? 1) - 1
            loadPage(at: target, column: column)
            try await awaitLoad()
            return [.integer(flags & 8 != 0 ? raw : currentByteOffset)]
        case "viewer.Select":
            guard let document = viewerDocument, let start = args.lua(1).hostInt, let length = args.lua(2).hostInt,
                  start >= 0, length >= 0, Int64(start) <= document.size, Int64(length) <= document.size - Int64(start) else { return [.bool(false)] }
            loadPage(at: Int64(start), selection: Int64(start)..<Int64(start + length))
            try await awaitLoad(); return [.bool(true)]
        case "viewer.SetMode":
            let props = args.lua(1).hostTable
            let names = ["VSMT_VIEWMODE":0, "VSMT_WRAP":1, "VSMT_WORDWRAP":2]
            guard let kind = props["Type"]?.hostInt ?? names[props["Type"]?.hostString ?? ""], let param = props["iParam"]?.hostInt else { return [.bool(false)] }
            switch kind {
            case 0: guard (0...2).contains(param) else { return [.bool(false)] }; mode.selectItem(at: param); applyMode(updateBase: true)
            case 1: wraps = param != 0; wrapButton.state = wraps ? .on : .off; loadPage(at: currentByteOffset)
            case 2: wordWrap = param != 0; loadPage(at: currentByteOffset)
            default: return [.bool(false)]
            }
            try await awaitLoad(); return [.bool(true)]
        default: throw ExtensionAPIError("API пока не перенесён: \(name)")
        }
    }
}

extension ViewerWindow {
    static func runLuaViewerUISmoke() async throws -> [String] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("far-lua-viewer-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("viewer.txt")
        let data = Data("alpha\nbeta\ngamma\n".utf8)
        try data.write(to: file)
        let viewer = try ViewerWindow(url: file, onEdit: { _, _, _ in false })
        defer { viewer.cancelBackgroundWork(); viewer.window?.close(); try? FileManager.default.removeItem(at: root) }
        viewer.showWindow(nil)
        let first = try await viewer.luaViewerCall("viewer.GetInfo", [])
        guard first.lua(0).hostTable["FileSize"] == .hostInteger(data.count) else { throw ExtensionAPIError("Lua viewer info must wait for the actual file snapshot") }
        let position = try await viewer.luaViewerCall("viewer.SetPosition", [.nilValue, .table(["StartPos":.integer(50), "Flags":.integer(2)])])
        guard position == [.integer(Int64(data.count / 2))] else { throw ExtensionAPIError("Lua viewer percent position must use byte offsets") }
        let relative = try await viewer.luaViewerCall("viewer.SetPosition", [.nilValue, .integer(-2), .integer(1), .integer(4)])
        guard relative == [.integer(Int64(data.count / 2 - 2))] else { throw ExtensionAPIError("Lua viewer relative offset was not applied") }
        let selected = try await viewer.luaViewerCall("viewer.Select", [.nilValue, .integer(0), .integer(5)])
        guard selected == [.bool(true)], (viewer.textView.string as NSString).substring(with: viewer.textView.selectedRange()) == "alpha" else { throw ExtensionAPIError("Lua viewer selection did not highlight requested bytes") }
        let mode = try await viewer.luaViewerCall("viewer.SetMode", [.nilValue, .table(["Type":.integer(0), "iParam":.integer(1), "Flags":.integer(0)])])
        guard mode == [.bool(true)], viewer.isHex, viewer.luaViewerInfo.hostTable["CurMode"]?.hostTable["ViewMode"] == .integer(1) else { throw ExtensionAPIError("Lua viewer must switch the real rendering mode") }
        guard try await viewer.luaViewerCall("viewer.Select", [.nilValue, .integer(Int64.max), .integer(2)]) == [.bool(false)] else { throw ExtensionAPIError("Lua viewer accepted an overflowing selection") }
        _ = try await viewer.luaViewerCall("viewer.SetPosition", [.nilValue, .table(["StartPos": .integer(0), "LeftPos": .integer(Int64.min)])])
        guard viewer.visibleColumn == 0 else { throw ExtensionAPIError("Lua viewer failed to clamp a negative horizontal position") }
        return ["Lua viewer waits for file info and uses zero-based byte offsets", "Lua viewer percentage and relative positions preserve file bounds", "Lua viewer selects actual bytes and switches the real HEX renderer"]
    }
}
