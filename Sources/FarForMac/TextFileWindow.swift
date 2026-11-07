import AppKit
import FarCore

/// Shared controls for the modal dialog and its AppKit smoke check.
@MainActor
private final class EditorSearchOptionsControls: NSObject {
    let regex = NSButton(checkboxWithTitle: "Регулярное выражение (в пределах строки)", target: nil, action: nil)
    let fuzzy = NSButton(checkboxWithTitle: "Нестрогий поиск (акценты, лигатуры, цифры)", target: nil, action: nil)
    let style = NSButton(checkboxWithTitle: "Сохранять стиль идентификаторов при замене", target: nil, action: nil)

    init(query: EditorSearchQuery?) {
        super.init()
        regex.state = query?.regex == true ? .on : .off
        fuzzy.state = query?.fuzzy == true ? .on : .off
        style.state = query?.preserveStyle == true ? .on : .off
        for control in [regex, fuzzy, style] { control.target = self; control.action = #selector(changed(_:)) }
    }

    @objc private func changed(_ sender: NSButton) {
        if sender.state == .on {
            for control in [regex, fuzzy, style] where control !== sender { control.state = .off }
        }
    }
}

/// Independent editor buffers. Persistent bytes, recovery and text operations
/// live in FarCore; this controller owns only the AppKit document experience.
@MainActor
final class TextFileWindow: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSMenuItemValidation {
    var macroEnvironment: MacroEnvironment {
        MacroEnvironment(context: .editor, fileName: workingCopyDisplayName ?? sourceURL?.lastPathComponent, isDirectory: false,
                         hasSelection: textView.selectedRange().length > 0, isEditable: editable)
    }
    static let helpText = """
    Редактор: F2 / ⌘S — сохранить; Shift F2 / ⇧⌘S — сохранить как.
    F7 / ⌘F — поиск; Shift F7 — далее; Alt F7 — назад; Ctrl F7 / ⌘⌥F — замена.
    Alt F8 / ⌘L — строка и столбец (абсолютные, +/−, %, hex); Ctrl F3 — номера строк.
    Ctrl Shift 0…9 — установить закладку; Ctrl 0…9 — перейти; кнопка «Закладки» — список.
    Поиск → «Все совпадения» — список до 10 000 результатов с переходом.
    Нестрогий поиск сводит акценты, лигатуры и варианты цифр; стиль замены сохраняет регистр и _-. / camelCase.
    Regex, нестрогий поиск и сохранение стиля выбираются по отдельности.
    Tab / Shift Tab или Alt I / Alt U — отступ / убрать отступ.
    Прямоугольный блок задаётся кнопкой «Блок» (строки включительно, последний столбец не включён).
    F6 — просмотр; F4 / F10 / Esc — закрыть; Shift F10 — сохранить и закрыть.
    ⌘Z / ⇧⌘Z — отменить / повторить. Shift F4 — открыть / создать файл, ⌘N — безымянный буфер.
    F8 — переключить ANSI / OEM, Shift F8 — выбрать кодовую страницу.
    F11 — команды плагинов. Ctrl [ / Ctrl ] — парная скобка, Shift добавляет выделение.
    Предел текста — 8 МиБ; подсветка отключается после 256 КиБ.
    Безымянный буфер: UTF-8 без BOM. Файл, названный при создании: CRLF и BOM для Unicode. Исходные и вставленные окончания строк сохраняются;
    преобразование всех окончаний выполняется только при явном выборе LF / CRLF / CR в «Сохранить как».
    """

    var isEditable: Bool { editable }
    var retainedArchiveWorkspace: ArchiveWorkspace?
    var retainedRemoteWorkspace: RemoteWorkspace?
    var workingCopyDisplayName: String? { didSet { updateState() } }
    var workingCopyDisplayPath: String? { didSet { updateState() } }
    private var displayName: String {
        if let workspace = retainedRemoteWorkspace, let sourceURL, sourceURL.path.hasPrefix(workspace.directory.path + "/"), let workingCopyDisplayName { return workingCopyDisplayName }
        return sourceURL?.lastPathComponent ?? "Без имени"
    }
    var onArchiveWorkingCopySaved: ((URL) -> Void)?
    var onWorkingCopyCloseRequested: (() -> Bool)?
    var onWorkingCopyView: ((URL, Int64, ViewerEncoding) -> Bool)? {
        didSet { viewButton?.isHidden = onView == nil && onWorkingCopyView == nil }
    }
    var hasUnsavedChanges: Bool { isDirty }
    var workingFileURL: URL? { sourceURL }
    var openCreateDirectory: URL { initialDirectory }
    static func openCreateRequest(in directory: URL) -> EditorOpenCreateRequest? { TextDocumentDialogs.openCreate(in: directory) }
    func saveForArchiveCommit() -> Bool { save() }
    func closeArchiveWorkingCopyWithoutSaving() { pendingDiscard = true; window?.close() }

    private let recoveryStore = AppRuntime.recoveryStore
    private let editable: Bool
    private let onView: ((URL, Int64, ViewerEncoding) -> Bool)?
    private var sourceURL: URL?
    private var initialDirectory: URL
    private var snapshot: EditorSnapshot?
    private var format: EditorFormat
    private var savedFormat: EditorFormat
    private var savedText: String
    private var recoveryID: UUID
    private var recoveredDraft = false
    private var pendingDiscard = false
    private var closed = false
    private var searchPending = false
    private let positionQueue = DispatchQueue(label: "far.editor.position", qos: .userInitiated)
    private var positionWork: DispatchWorkItem?
    private var requestedPositionRevision = -1
    private var requestedPositionOffset = -1
    private var cachedPositionRevision = -1
    private var cachedPositionOffset = -1
    private var cachedPosition = (line: 1, column: 1)
    private struct HistoryRecord: Codable {
        let path: String
        let identity: String
        let encoding: ViewerEncoding
        let position: Int
        var bookmarks: EditorBookmarks?
        let date: Date
    }
    private static let historyDefaultsKey = "editor.history.v1"
    private static func historyRecords() -> [HistoryRecord] {
        guard let data = AppPreferences.defaults.data(forKey: historyDefaultsKey) else { return [] }
        return (try? JSONDecoder().decode([HistoryRecord].self, from: data)) ?? []
    }
    private static func historyRecord(_ url: URL) -> HistoryRecord? {
        historyRecords().first { $0.path == url.standardizedFileURL.path }
    }
    private func persistHistory() {
        guard luaAllowPositionHistory, luaSavePosition, retainedArchiveWorkspace == nil, retainedRemoteWorkspace == nil,
              let sourceURL, let snapshot else { return }
        let record = HistoryRecord(path: sourceURL.standardizedFileURL.path, identity: snapshot.identity,
                                   encoding: snapshot.format.encoding, position: textView.selectedRange().location, bookmarks: isDirty ? nil : bookmarks, date: Date())
        var records = Self.historyRecords().filter { $0.path != record.path }; records.append(record)
        records.sort { $0.date > $1.date }
        if let data = try? JSONEncoder().encode(Array(records.prefix(100))) { AppPreferences.defaults.set(data, forKey: Self.historyDefaultsKey) }
    }
    private var keyMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var retainedWhileOpen: TextFileWindow?
    private let textView = EditorTextView(frame: .zero)
    private let scroll = NSScrollView()
    private var ruler: EditorLineRuler?
    private let nameLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "F2 Сохранить", target: nil, action: nil)
    private var viewButton: NSButton?
    private let syntaxPopup = NSPopUpButton()
    private let tabsPopup = NSPopUpButton()
    private let spacesCheck = NSButton(checkboxWithTitle: "Пробелы", target: nil, action: nil)
    private var selectedSyntax: String? // nil selects a provider by filename; "none" disables it.
    private var generation = 0
    private var searchGeneration = 0
    private var highlightGeneration = 0
    private var lastFoundRange: NSRange?
    private var lastFoundQuery: EditorSearchQuery?
    private var highlightWork: DispatchWorkItem?
    private var recoveryWork: DispatchWorkItem?
    private let recoveryQueue = DispatchQueue(label: "far.editor.recovery", qos: .utility)
    private var recoveryWarning = ""
    private var operationStatus = ""
    private var lastNotifiedIdentity: String?
    private var isCheckingExternal = false
    private var presentingExternalConflict = false
    private var externalCheckGeneration = 0
    private var lastQuery: EditorSearchQuery?
    private var lastReplacement = ""
    private var lastSearchWasReplacement = false
    private var rectangle: EditorRectangle?
    private var luaRectangle: EditorRectangle?
    private var luaStream: NSRange?
    private var luaCaret: Int?
    private var luaSelectionStart: Int?
    private var installingLuaSelection = false
    private var luaUndoLevels: [Int] = []
    private var luaTitle: String?
    private var luaReadSent = false
    private var luaCoordinateGeneration = -1
    private var luaCoordinateCache: FarEditorCoordinates?
    private var luaWasSaved = false
    private var luaAllowPositionHistory = true
    private var luaSavePosition = true
    private var luaRedrawScheduled = false
    private var luaColorPaintScheduled = false
    private var luaColors: [LuaEditorColor] = []
    private var syntaxSpans: [EditorSyntaxSpan] = []
    private var drawLineMode: EditorDrawLine?
    private var drawLineUndoLevel: Int?
    var drawLineActive: Bool { drawLineMode != nil }
    private var bookmarks = EditorBookmarks()
    private var bookmarkText = ""
    private var pendingBookmarkChanges: [EditorTextChange]?
    private var tabSize = 4
    private var useSpaces = true
    private static let foreground = NSColor(calibratedRed: 0.88, green: 0.92, blue: 1, alpha: 1)
    private static let background = NSColor(calibratedRed: 0.035, green: 0.065, blue: 0.14, alpha: 1)

    init(url: URL, editable: Bool = true, initialByteOffset: Int64? = nil,
         encoding: ViewerEncoding = .automatic, useRememberedEncoding: Bool = true,
         onView: ((URL, Int64, ViewerEncoding) -> Bool)? = nil) throws {
        let history = Self.historyRecord(url)
        let loaded: EditorSnapshot
        if encoding == .automatic, useRememberedEncoding, let rememberedEncoding = history?.encoding {
            do { loaded = try EditorDocument.load(url: url, encoding: rememberedEncoding) }
            catch { loaded = try EditorDocument.load(url: url, encoding: .automatic) }
        } else { loaded = try EditorDocument.load(url: url, encoding: encoding) }
        sourceURL = loaded.originalURL; initialDirectory = loaded.originalURL.deletingLastPathComponent()
        snapshot = loaded; format = loaded.format; savedFormat = loaded.format; savedText = loaded.text
        recoveryID = UUID(); self.editable = editable; self.onView = onView
        super.init(window: Self.makeWindow())
        configureContent(loaded.text)
        if history?.identity == loaded.identity { bookmarks = history?.bookmarks ?? EditorBookmarks() }
        let position = initialByteOffset.map { EditorDocument.utf16Offset(forByteOffset: $0, in: loaded) }
            ?? (history?.identity == loaded.identity ? history?.position ?? 0 : 0)
        select(NSRange(location: min(position, loaded.text.utf16.count), length: 0))
        updateState(); scheduleHighlight()
    }

    convenience init(newAt url: URL, encoding: ViewerEncoding, editable: Bool = true, onView: ((URL, Int64, ViewerEncoding) -> Bool)? = nil) {
        let codePage = encoding == .automatic ? TextDocumentDialogs.systemCodePages[0] : encoding
        let unicode = codePage == .utf8 || codePage == .utf16LE || codePage == .utf16BE
        self.init(newIn: url.deletingLastPathComponent(), named: url,
                  format: EditorFormat(encoding: codePage, bom: unicode, lineEnding: .crlf), editable: editable, onView: onView)
    }

    init(newIn directory: URL, named url: URL? = nil, format: EditorFormat = EditorFormat(), editable: Bool = true,
         onView: ((URL, Int64, ViewerEncoding) -> Bool)? = nil) {
        sourceURL = url; initialDirectory = directory; snapshot = nil
        self.format = format; savedFormat = format; savedText = ""; recoveryID = UUID()
        self.editable = editable; self.onView = onView
        super.init(window: Self.makeWindow())
        configureContent(""); updateState()
    }

    init(recovery: EditorRecoveryRecord, onView: ((URL, Int64, ViewerEncoding) -> Bool)? = nil) throws {
        sourceURL = recovery.sourceURL; initialDirectory = recovery.sourceURL?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
        // A recovered draft never gains permission to overwrite today's source.
        // A matching base identity permits a normal safe save; otherwise Save As is required.
        let current: EditorSnapshot?
        if let url = recovery.sourceURL { current = try? EditorDocument.load(url: url, encoding: recovery.format.encoding) }
        else { current = nil }
        snapshot = current?.identity == recovery.baseIdentity ? current : nil
        format = recovery.format; savedFormat = current?.format ?? recovery.format
        savedText = current?.text ?? ""; recoveryID = recovery.id; recoveredDraft = true
        editable = true; self.onView = onView
        super.init(window: Self.makeWindow())
        configureContent(recovery.text)
        select(NSRange(location: min(max(0, recovery.selection), recovery.text.utf16.count), length: 0))
        operationStatus = "Восстановленный черновик; проверьте текст и сохраните"
        updateState(); scheduleHighlight()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    static func pendingRecoveries() throws -> [EditorRecoveryRecord] { try AppRuntime.recoveryStore.loadAll() }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 800, height: 420)
        window.appearance = NSAppearance(named: .darkAqua); window.backgroundColor = background; window.center()
        return window
    }


    override func showWindow(_ sender: Any?) {
        if let view = window?.contentView { UIAccessibility.apply(to: view) }
        retainedWhileOpen = self; window?.delegate = self
        super.showWindow(sender); window?.makeFirstResponder(textView)
        textView.scrollRangeToVisible(textView.selectedRange())
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window, self.window?.attachedSheet == nil,
                      self.window?.isKeyWindow == true else { return event }
                if self.drawLineActive { return self.drawLineKey(event) ? nil : event }
                if FarLuaWorkspace.shared.handle(event) || HlfViewerWorkspace.shared.handleEditorKey(event) || CommandWorkspace.shared.handle(event) { return nil }
                return self.handleKey(event) ? nil : event
            }
        }
        if activationObserver == nil {
            activationObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.checkExternalChange() }
            }
        }
        if !luaReadSent {
            luaReadSent = true
            luaEditorEvent(0)
        }
        luaRequestRedraw()
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let result = NSButton(title: title, target: self, action: action)
        result.bezelStyle = .rounded; return result
    }

    private func configureContent(_ contents: String) {
        guard let content = window?.contentView else { return }
        window?.delegate = self
        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.font = .systemFont(ofSize: 11); pathLabel.textColor = .secondaryLabelColor
        pathLabel.isSelectable = true; pathLabel.lineBreakMode = .byTruncatingMiddle
        syntaxPopup.addItems(withTitles: ["Подсветка: Авто", "Без подсветки"] + EditorSyntaxRegistry.providers.map(\.title))
        syntaxPopup.target = self; syntaxPopup.action = #selector(syntaxChanged(_:))
        syntaxPopup.setContentHuggingPriority(.required, for: .horizontal)
        let heading = NSStackView(views: [nameLabel, NSView(), syntaxPopup])
        heading.orientation = .horizontal
        let header = NSStackView(views: [heading, pathLabel]); header.orientation = .vertical; header.alignment = .leading; header.spacing = 4
        let findButton = button("F7 Поиск", #selector(findDocument(_:)))
        let replaceButton = button("Замена", #selector(replaceDocument(_:))); replaceButton.isHidden = !editable
        let gotoButton = button("Строка…", #selector(gotoDocument(_:)))
        let blockButton = button("Блок…", #selector(blockDocument(_:))); blockButton.isHidden = !editable
        let lineButton = button("№", #selector(toggleLineNumbers(_:))); lineButton.toolTip = "Ctrl F3 — номера строк"
        let bookmarkButton = button("Закладки…", #selector(bookmarksDocument(_:)))
        tabsPopup.addItems(withTitles: ["Tab 2", "Tab 4", "Tab 8"]); tabsPopup.selectItem(at: 1)
        tabsPopup.target = self; tabsPopup.action = #selector(tabsChanged(_:))
        spacesCheck.state = .on; spacesCheck.target = self; spacesCheck.action = #selector(tabsChanged(_:))
        let toolbar = NSStackView(views: [findButton, replaceButton, gotoButton, blockButton, lineButton, bookmarkButton, NSView(), tabsPopup, spacesCheck])
        toolbar.orientation = .horizontal; toolbar.spacing = 8
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder; scroll.backgroundColor = Self.background
        textView.frame = NSRect(x: 0, y: 0, width: 1000, height: 500)
        textView.isRichText = false; textView.importsGraphics = false; textView.isEditable = editable
        textView.isSelectable = true; textView.allowsUndo = editable
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = Self.background; textView.textColor = Self.foreground; textView.insertionPointColor = .white
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isAutomaticQuoteSubstitutionEnabled = false; textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false; textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false; textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false; textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]; textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = textView.maxSize; textView.textContainer?.widthTracksTextView = false
        textView.string = contents; textView.delegate = self; bookmarkText = contents
        textView.indentSelection = { outdent in CommandWorkspace.shared.dispatch(outdent ? "editor.outdent" : "editor.indent") }
        textView.beforeUserInput = { [weak self] in self?.trackAutoWrap() }
        scroll.documentView = textView
        ruler = EditorLineRuler(scrollView: scroll, editor: textView)
        scroll.verticalRulerView = ruler; scroll.hasVerticalRuler = true; scroll.rulersVisible = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        configureTabs()
        statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        saveButton.target = self; saveButton.action = #selector(saveDocument(_:)); saveButton.bezelStyle = .rounded; saveButton.isHidden = !editable
        let saveAsButton = button("Сохранить как…", #selector(saveAsDocument(_:))); saveAsButton.isHidden = !editable
        let viewButton = button("F6 Просмотр", #selector(switchToViewer(_:))); self.viewButton = viewButton
        viewButton.isHidden = onView == nil && onWorkingCopyView == nil
        let closeButton = button("Закрыть", #selector(closeRequested(_:)))
        let footer = NSStackView(views: [statusLabel, NSView(), viewButton, saveButton, saveAsButton, closeButton])
        footer.orientation = .horizontal; footer.spacing = 8
        for view in [header, toolbar, scroll, footer] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14), header.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            heading.widthAnchor.constraint(equalTo: header.widthAnchor), pathLabel.widthAnchor.constraint(equalTo: header.widthAnchor),
            toolbar.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 9), toolbar.leadingAnchor.constraint(equalTo: header.leadingAnchor), toolbar.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8), scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8), footer.leadingAnchor.constraint(equalTo: header.leadingAnchor), footer.trailingAnchor.constraint(equalTo: header.trailingAnchor), footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)
        ])
    }

    private var isDirty: Bool { editable && (recoveredDraft || textView.string != savedText || format != savedFormat) }
    func textDidChange(_ notification: Notification) {
        let previous = bookmarkText
        luaCaret = nil; luaStream = nil; luaRectangle = nil; luaSelectionStart = nil
        luaColors.removeAll()
        if let changes = pendingBookmarkChanges { bookmarks.apply(changes: changes) }
        else { bookmarks.update(from: bookmarkText, to: textView.string) }
        pendingBookmarkChanges = nil; bookmarkText = textView.string
        generation += 1; searchGeneration += 1; searchPending = false; lastFoundRange = nil; operationStatus = ""; pendingDiscard = false
        updateState(); ruler?.needsDisplay = true; scheduleHighlight(); scheduleRecovery()
        luaEditorChanged(from: previous, to: textView.string)
        luaRequestRedraw()
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        if !installingLuaSelection {
            luaCaret = nil; luaStream = nil; luaRectangle = nil
            luaRequestRedraw()
        }
        updateState(); ruler?.needsDisplay = true
    }
    private func withinBufferLimit(_ text: String) -> Bool {
        // Count encoded width without transcoding the whole buffer on every key.
        // Legacy drafts may contain temporarily unrepresentable characters;
        // recovery keeps them, while the storage codec refuses a lossy save.
        let bom = format.bom ? (format.encoding == .utf8 ? 3 : 2) : 0
        let bytes: Int
        switch format.encoding {
        case .utf8, .automatic: bytes = text.utf8.count
        case .utf16LE, .utf16BE: bytes = text.utf16.count * 2
        case .windows1251, .windows1252, .latin1, .dos437, .dos866: bytes = text.unicodeScalars.count
        }
        return bytes + bom <= EditorDocument.maximumSize
    }
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard let replacementString else { return true }
        let updated = (textView.string as NSString).replacingCharacters(in: affectedCharRange, with: replacementString)
        guard withinBufferLimit(updated) else { operationStatus = "Изменение отклонено: предел текста 8 МиБ"; updateState(); NSSound.beep(); return false }
        pendingBookmarkChanges = [EditorTextChange(range: affectedCharRange, replacementUTF16Length: replacementString.utf16.count)]
        return true
    }
    @objc private func scrolled(_ notification: Notification) {
        ruler?.needsDisplay = true
        if !installingLuaSelection { luaRequestRedraw() }
    }

    private func updateState() {
        let name = displayName
        nameLabel.stringValue = name + (editable ? "" : " · Только чтение")
        pathLabel.stringValue = (displayName == workingCopyDisplayName ? workingCopyDisplayPath : nil) ?? sourceURL?.path ?? initialDirectory.path + "/ — новый файл"
        let drawing = drawLineMode.map { $0.doubleLine ? "Shift+←↑↓→ рисует ╬" : "Shift+←↑↓→ рисует ┼" }
        window?.title = drawing ?? luaTitle ?? (name + (editable ? " — Редактор" : " — Просмотр"))
        window?.representedURL = sourceURL; window?.isDocumentEdited = isDirty
        saveButton.isEnabled = editable && (isDirty || snapshot == nil)
        let offset = textView.selectedRange().location
        let positionText: String
        if cachedPositionRevision == generation, cachedPositionOffset == offset { positionText = "\(cachedPosition.line):\(cachedPosition.column)" }
        else { positionText = "…"; schedulePosition(offset: offset) }
        let syntax = textView.string.utf8.count > 256 * 1024 ? " · Подсветка выключена: >256 КиБ" : ""
        let extra = recoveryWarning.isEmpty ? operationStatus : recoveryWarning
        statusLabel.stringValue = drawing.map { $0 + " · F1 — справка · F2 — стиль · F10 — выход" } ??
            "\(positionText) · \(format.encoding.title)\(format.bom ? " BOM" : "") · \(format.lineEnding.title)\(isDirty ? " · Изменён" : "")\(syntax)\(extra.isEmpty ? "" : " · " + extra)"
    }

    private func schedulePosition(offset: Int) {
        guard requestedPositionRevision != generation || requestedPositionOffset != offset else { return }
        requestedPositionRevision = generation; requestedPositionOffset = offset
        positionWork?.cancel()
        let text = textView.string, revision = generation
        let work = DispatchWorkItem { [weak self] in
            let position = EditorEditing.lineColumn(in: text, offset: offset)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, self.generation == revision, self.textView.selectedRange().location == offset else { return }
                self.cachedPosition = position; self.cachedPositionOffset = offset; self.cachedPositionRevision = revision
                self.updateState()
            }
        }
        positionWork = work; positionQueue.asyncAfter(deadline: .now() + 0.04, execute: work)
    }

    private func select(_ range: NSRange) {
        let length = textView.string.utf16.count
        let location = min(max(0, range.location), length)
        textView.setSelectedRange(NSRange(location: location, length: min(range.length, length - location)))
        textView.scrollRangeToVisible(textView.selectedRange()); updateState()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(saveDocument(_:)): return editable && (isDirty || snapshot == nil)
        case #selector(saveAsDocument(_:)): return editable
        default: return true
        }
    }
    @objc func saveDocument(_ sender: Any?) { _ = save() }
    @discardableResult private func save() -> Bool {
        guard editable else { return true }
        guard let sourceURL, snapshot != nil || !recoveredDraft else { return saveAs() }
        guard isDirty || snapshot == nil else { return true }
        do {
            let result = try EditorDocument.save(text: textView.string, format: format, to: sourceURL, expected: snapshot)
            didSave(result); return true
        } catch EditorError.changed { externalChangeChoices(); return false }
        catch { showError("Не удалось сохранить файл", error); return false }
    }

    private func didSave(_ result: EditorSnapshot) {
        snapshot = result; sourceURL = result.originalURL; initialDirectory = result.originalURL.deletingLastPathComponent()
        savedText = result.text; format = result.format; savedFormat = result.format; recoveredDraft = false
        if textView.string != result.text { replaceBuffer(result.text, selection: textView.selectedRange(), action: "Окончания строк") }
        textView.breakUndoCoalescing(); clearRecovery(); operationStatus = "Сохранено"; lastNotifiedIdentity = nil
        updateState(); scheduleHighlight()
        onArchiveWorkingCopySaved?(result.originalURL)
        luaWasSaved = true
        if luaReadSent, FarLuaWorkspace.shared.hasEventHandlers("EditorEvent") {
            let source = result.text as NSString
            let eol = FarEditorCoordinates(result.text).lines.first(where: { $0.ending.length > 0 }).map { source.substring(with: $0.ending) } ?? ""
            luaEditorEvent(1, .table(["FileName": .string(luaEditorFilename), "FileEOL": .string(eol),
                "CodePage": .hostInteger(Self.luaCodePage(result.format.encoding))]))
        }
    }

    @objc func saveAsDocument(_ sender: Any?) { _ = saveAs() }
    @discardableResult private func saveAs(requireCopy: Bool = false) -> Bool {
        guard editable else { return false }
        let panel = NSSavePanel(); panel.title = "Сохранить текст как"
        panel.directoryURL = sourceURL?.deletingLastPathComponent() ?? initialDirectory
        panel.nameFieldStringValue = sourceURL == nil ? "Новый файл.txt" : displayName
        let encodings = ViewerEncoding.allCases.filter { $0 != .automatic }
        let encodingPopup = NSPopUpButton(); encodingPopup.addItems(withTitles: encodings.map(\.title))
        encodingPopup.selectItem(at: encodings.firstIndex(of: format.encoding) ?? 0)
        let bomCheck = NSButton(checkboxWithTitle: "BOM (UTF-8 / UTF-16)", target: nil, action: nil); bomCheck.state = format.bom ? .on : .off
        let eolPopup = NSPopUpButton(); eolPopup.addItems(withTitles: EditorLineEnding.allCases.map(\.title)); eolPopup.selectItem(at: EditorLineEnding.allCases.firstIndex(of: format.lineEnding) ?? 0)
        let accessory = NSStackView(views: [row("Кодировка", encodingPopup), bomCheck, row("Строки", eolPopup)])
        accessory.orientation = .vertical; accessory.alignment = .leading; accessory.spacing = 8
        accessory.frame = NSRect(x: 0, y: 0, width: 420, height: 108); panel.accessoryView = accessory
        guard panel.runModal() == .OK, let destination = panel.url else { return false }
        if requireCopy, let sourceURL,
           destination.standardizedFileURL.resolvingSymlinksInPath() == sourceURL.standardizedFileURL.resolvingSymlinksInPath() {
            showError("Выберите другое имя для копии", EditorError.changed)
            return false
        }
        let requested = EditorFormat(encoding: encodings[max(0, encodingPopup.indexOfSelectedItem)], bom: bomCheck.state == .on, lineEnding: EditorLineEnding.allCases[max(0, eolPopup.indexOfSelectedItem)])
        do {
            // Capture the version only after the save panel's replace confirmation.
            // The actual writer rechecks it again immediately before replacement.
            let expected: EditorSnapshot?
            if let snapshot, destination.standardizedFileURL == snapshot.originalURL || destination.standardizedFileURL == snapshot.url {
                // Saving under the current name retains its original conflict baseline.
                expected = snapshot
            } else if FileManager.default.fileExists(atPath: destination.path) {
                do { expected = try EditorDocument.load(url: destination, encoding: .automatic) }
                catch { expected = try EditorDocument.load(url: destination, encoding: requested.encoding) }
            } else { expected = nil }
            let result = try EditorDocument.save(text: textView.string, format: requested, to: destination, expected: expected)
            didSave(result); return true
        } catch { showError("Не удалось сохранить файл", error); return false }
    }

    private func row(_ label: String, _ view: NSView) -> NSStackView {
        let title = NSTextField(labelWithString: label); title.widthAnchor.constraint(equalToConstant: 95).isActive = true
        let row = NSStackView(views: [title, view]); row.orientation = .horizontal; row.spacing = 10; return row
    }
    private func field(_ value: String = "", placeholder: String = "") -> NSTextField {
        let field = NSTextField(string: value); field.placeholderString = placeholder
        field.cell?.sendsActionOnEndEditing = false; field.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        return field
    }
    private func showError(_ title: String, _ error: Error) {
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = title; alert.informativeText = error.localizedDescription; alert.runModal()
    }

    private func clearRecovery() {
        recoveryWork?.cancel(); recoveryWork = nil
        let id = recoveryID, store = recoveryStore
        recoveryQueue.async { [weak self] in
            do {
                try store.remove(id: id)
                DispatchQueue.main.async { [weak self] in self?.recoveryWarning = ""; self?.updateState() }
            } catch {
                let message = "Черновик восстановления не удалён: " + error.localizedDescription
                DispatchQueue.main.async { [weak self] in self?.recoveryWarning = message; self?.updateState() }
            }
        }
    }
    private func scheduleRecovery() {
        recoveryWork?.cancel()
        guard retainedArchiveWorkspace == nil, retainedRemoteWorkspace == nil, editable, isDirty else { clearRecovery(); return }
        let record = EditorRecoveryRecord(id: recoveryID, sourceURL: sourceURL, text: textView.string, format: format,
                                          selection: textView.selectedRange().location, baseIdentity: snapshot?.identity)
        let store = recoveryStore
        let work = DispatchWorkItem { [weak self] in
            do {
                try store.save(record)
                DispatchQueue.main.async { [weak self] in self?.recoveryWarning = ""; self?.updateState() }
            } catch {
                let message = "Черновик не сохранён: " + error.localizedDescription
                DispatchQueue.main.async { [weak self] in self?.recoveryWarning = message; self?.updateState() }
            }
        }
        recoveryWork = work; recoveryQueue.asyncAfter(deadline: .now() + 0.65, execute: work)
    }

    private func checkExternalChange() {
        guard !closed, !isCheckingExternal, !presentingExternalConflict, NSApp.modalWindow == nil, window?.isVisible == true, window?.attachedSheet == nil, let sourceURL, let snapshot else { return }
        isCheckingExternal = true
        let checkGeneration = externalCheckGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let current = try? EditorDocument.load(url: sourceURL, encoding: snapshot.format.encoding)
            let identity = current?.identity ?? (try? LocalViewerSource(url: sourceURL))?.identity ?? "missing"
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.isCheckingExternal = false
                guard !self.closed, !self.presentingExternalConflict, self.externalCheckGeneration == checkGeneration,
                      self.window?.isVisible == true, NSApp.modalWindow == nil else { return }
                guard self.snapshot?.identity == snapshot.identity,
                      current?.identity != snapshot.identity || current?.data != snapshot.data else { return }
                guard self.lastNotifiedIdentity != identity else { return }
                self.lastNotifiedIdentity = identity
                self.externalChangeChoices()
            }
        }
    }
    private func externalChangeChoices() {
        guard !closed, !presentingExternalConflict, NSApp.modalWindow == nil, let sourceURL else { return }
        presentingExternalConflict = true
        // Invalidate checks started before a save discovered this conflict.
        // Mark this concrete disk version handled before the modal dialog can
        // cause any didBecomeKey callbacks when it closes or opens Compare.
        externalCheckGeneration += 1
        lastNotifiedIdentity = (try? LocalViewerSource(url: sourceURL))?.identity ?? "missing"
        defer { presentingExternalConflict = false; externalCheckGeneration += 1 }
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "Файл изменён другой программой"
        alert.informativeText = "Ваш текст остаётся в редакторе. Можно перечитать файл, сохранить текущий буфер копией или открыть версию с диска для сравнения."
        alert.addButton(withTitle: "Сохранить копию…"); alert.addButton(withTitle: "Перечитать…")
        alert.addButton(withTitle: "Сравнить"); alert.addButton(withTitle: "Оставить буфер")
        switch alert.runModal() {
        case .alertFirstButtonReturn: _ = saveAs(requireCopy: true)
        case .alertSecondButtonReturn:
            if isDirty {
                let confirm = NSAlert(); confirm.messageText = "Заменить буфер версией с диска?"
                confirm.informativeText = "Несохранённые правки будут отброшены."
                confirm.addButton(withTitle: "Перечитать"); confirm.addButton(withTitle: "Отмена")
                guard confirm.runModal() == .alertFirstButtonReturn else { return }
            }
            do {
                let loaded = try EditorDocument.load(url: sourceURL, encoding: format.encoding)
                snapshot = loaded; format = loaded.format; savedFormat = loaded.format; savedText = loaded.text; recoveredDraft = false
                textView.string = loaded.text; bookmarkText = loaded.text; bookmarks = EditorBookmarks(); textView.undoManager?.removeAllActions()
                generation += 1; searchGeneration += 1; clearRecovery(); select(NSRange(location: 0, length: 0)); scheduleHighlight()
            } catch { showError("Не удалось перечитать файл", error) }
        case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 2):
            do { let other = try TextFileWindow(url: sourceURL, editable: false, encoding: format.encoding); other.showWindow(nil)
                operationStatus = "Для сравнения открыта отдельная версия с диска"; updateState()
            } catch { showError("Не удалось открыть версию с диска", error) }
        default: break
        }
    }

    @objc private func closeRequested(_ sender: Any?) { window?.performClose(sender) }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard confirmClose() else { return false }
        return onWorkingCopyCloseRequested?() ?? true
    }
    func confirmClose() -> Bool {
        pendingDiscard = false
        guard isDirty else { return true }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "Сохранить изменения в «\(displayName)»?"
        alert.informativeText = "Закрытие без сохранения удалит и черновик восстановления."
        alert.addButton(withTitle: "Сохранить"); alert.addButton(withTitle: "Не сохранять"); alert.addButton(withTitle: "Отмена")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertSecondButtonReturn: pendingDiscard = true; return true
        default: return false
        }
    }
    @objc private func switchToViewer(_ sender: Any?) {
        guard let onView = onWorkingCopyView ?? onView else { return }
        if snapshot == nil, !save() { return }
        guard confirmClose(), let sourceURL else { return }
        let displayed = isDirty ? savedText : textView.string
        do {
            let offset = try EditorDocument.byteOffset(forUTF16Offset: min(textView.selectedRange().location, displayed.utf16.count), text: displayed, format: savedFormat)
            if onView(sourceURL, offset, savedFormat.encoding) {
                if onWorkingCopyView != nil {
                    if pendingDiscard && isDirty {
                        format = savedFormat; recoveredDraft = false
                        replaceBuffer(savedText, selection: textView.selectedRange(), action: "Отбросить изменения")
                        textView.undoManager?.removeAllActions(); clearRecovery(); pendingDiscard = false
                    }
                    window?.orderOut(nil)
                } else { window?.close() }
            } else { pendingDiscard = false }
        } catch { showError("Не удалось перейти к просмотру", error) }
    }
    func switchWorkingCopyToViewer() { switchToViewer(nil) }
    /// Called after every app termination guard has accepted closing.
    func finalizeClose() {
        persistHistory()
        recoveryWork?.cancel()
        if pendingDiscard || !isDirty {
            do { try recoveryQueue.sync { try recoveryStore.remove(id: recoveryID) } }
            catch { showError("Черновик восстановления не удалён", error) }
        } else {
            // Finish a successful save's queued removal before Cmd-Q exits.
            recoveryQueue.sync {}
        }
    }
    func moveToByteOffset(_ offset: Int64) {
        guard let snapshot, textView.string == snapshot.text else { return }
        select(NSRange(location: EditorDocument.utf16Offset(forByteOffset: offset, in: snapshot), length: 0))
    }

    private func selectCodePage() {
        if let encoding = TextDocumentDialogs.codePage(current: format.encoding) { changeCodePage(encoding) }
    }

    private func changeCodePage(_ encoding: ViewerEncoding) {
        guard encoding != format.encoding else { return }
        let unicode16: [ViewerEncoding] = [.utf16LE, .utf16BE]
        let selection = textView.selectedRange()
        do {
            if let sourceURL, let snapshot, !isDirty || encoding == .automatic || unicode16.contains(format.encoding) || unicode16.contains(encoding) {
                let loaded = try EditorDocument.load(url: sourceURL, encoding: encoding)
                if isDirty {
                    let confirm = NSAlert()
                    confirm.messageText = "Перечитать файл в другой кодовой странице?"
                    confirm.informativeText = "Несохранённые правки будут отброшены."
                    confirm.addButton(withTitle: "Перечитать")
                    confirm.addButton(withTitle: "Отмена")
                    guard confirm.runModal() == .alertFirstButtonReturn else { return }
                }
                let diskOffset = try EditorDocument.byteOffset(forUTF16Offset: selection.location, text: snapshot.text, format: snapshot.format)
                self.snapshot = loaded; format = loaded.format; savedFormat = loaded.format; savedText = loaded.text
                recoveredDraft = false; lastNotifiedIdentity = nil
                let newSelection = NSRange(location: EditorDocument.utf16Offset(forByteOffset: diskOffset, in: loaded), length: 0)
                installCodePageText(loaded.text, selection: newSelection)
                clearRecovery()
            } else if snapshot == nil {
                let selected = encoding == .automatic ? TextDocumentDialogs.systemCodePages[0] : encoding
                let hasBOM = unicode16.contains(selected) || selected == .utf8 && format.bom
                let updated = EditorFormat(encoding: selected, bom: hasBOM, lineEnding: format.lineEnding)
                _ = try EditorDocument.encode(text: textView.string, format: updated)
                format = updated; scheduleRecovery()
            } else {
                let bytes = try EditorDocument.encode(text: textView.string, format: format)
                let converted = try EditorDocument.decode(bytes, encoding: encoding)
                format = converted.format
                installCodePageText(converted.text, selection: selection)
                scheduleRecovery()
            }
            operationStatus = "Кодовая страница: \(format.encoding.title)"; updateState()
        } catch { showError("Кодовая страница не изменена", error) }
    }

    private func installCodePageText(_ text: String, selection: NSRange) {
        if textView.string != text { bookmarks = EditorBookmarks() }
        textView.string = text; bookmarkText = text; pendingBookmarkChanges = nil
        textView.undoManager?.removeAllActions()
        generation += 1; searchGeneration += 1; searchPending = false; lastFoundRange = nil
        select(selection); scheduleHighlight()
    }
    func windowWillClose(_ notification: Notification) {
        luaFinishUndoGroups()
        stopDrawLine()
        luaEditorEvent(3)
        finalizeClose(); closed = true
        highlightWork?.cancel(); positionWork?.cancel(); searchGeneration += 1
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver); self.activationObserver = nil }
        NotificationCenter.default.removeObserver(self)
        window?.delegate = nil; retainedWhileOpen = nil
        retainedArchiveWorkspace = nil
        retainedRemoteWorkspace = nil
    }

    @objc func findDocument(_ sender: Any?) { searchDialog(replacing: false) }
    @objc func replaceDocument(_ sender: Any?) { guard editable else { return }; searchDialog(replacing: true) }
    private func searchDialog(replacing: Bool) {
        let alert = NSAlert(); alert.messageText = replacing ? "Замена" : "Поиск"
        let pattern = field(lastQuery?.pattern ?? "", placeholder: "Текст или построчное выражение")
        let replacement = field(lastReplacement, placeholder: "Замена ($1 для regex)")
        let options = EditorSearchOptionsControls(query: lastQuery)
        let caseSensitive = NSButton(checkboxWithTitle: "Учитывать регистр", target: nil, action: nil)
        caseSensitive.state = lastQuery?.caseSensitive == true ? .on : .off
        let words = NSButton(checkboxWithTitle: "Целые слова", target: nil, action: nil)
        words.state = lastQuery?.wholeWords == true ? .on : .off
        var views: [NSView] = [row("Найти", pattern)]
        if replacing { views.append(row("Заменить", replacement)) }
        views += [caseSensitive, words, options.fuzzy, options.regex]
        if replacing { views.append(options.style) }
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 9
        stack.frame = NSRect(x: 0, y: 0, width: 480, height: replacing ? 222 : 152); alert.accessoryView = stack
        alert.addButton(withTitle: replacing ? "Заменить далее" : "Найти далее")
        alert.addButton(withTitle: replacing ? "Заменить назад" : "Найти назад")
        if !replacing { alert.addButton(withTitle: "Все совпадения") }
        alert.addButton(withTitle: "Отмена").keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = pattern
        let answer = alert.runModal()
        guard answer == .alertFirstButtonReturn || answer == .alertSecondButtonReturn || (!replacing && answer == .alertThirdButtonReturn) else { return }
        let query = EditorSearchQuery(pattern: pattern.stringValue, regex: options.regex.state == .on,
                                      caseSensitive: caseSensitive.state == .on, wholeWords: words.state == .on,
                                      fuzzy: options.fuzzy.state == .on, preserveStyle: options.style.state == .on)
        lastQuery = query
        lastSearchWasReplacement = replacing
        let direction: ViewerSearchDirection = answer == .alertSecondButtonReturn ? .backward : .forward
        if replacing {
            lastReplacement = replacement.stringValue
            performReplacement(query: query, replacement: lastReplacement, direction: direction)
        } else if answer == .alertThirdButtonReturn { findAll(query) }
        else { find(query, direction: direction) }
    }

    private func continueSearch(direction: ViewerSearchDirection) {
        guard let lastQuery else { findDocument(nil); return }
        if lastSearchWasReplacement, editable {
            let selection = textView.selectedRange()
            var start = direction == .forward ? NSMaxRange(selection) : selection.location
            if direction == .forward, selection.length == 0, lastFoundRange == selection, lastFoundQuery == lastQuery { start += 1 }
            performReplacement(query: lastQuery, replacement: lastReplacement, direction: direction, from: start)
        } else { find(lastQuery, direction: direction) }
    }

    private func findAll(_ query: EditorSearchQuery) {
        let text = textView.string, revision = generation
        searchGeneration += 1; let request = searchGeneration
        searchPending = true; operationStatus = "Поиск… (Esc — отменить)"; updateState()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try EditorEditing.allMatches(in: text, query: query) }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, self.generation == revision, self.searchGeneration == request else { return }
                self.searchPending = false
                switch result {
                case .success(let matches):
                    self.operationStatus = "Совпадений: \(matches.matches.count)\(matches.truncated ? " (список ограничен)" : "")"
                    let results = EditorSearchResultsWindow(result: matches) { [weak self] range in
                        guard let self, !self.closed else { return }
                        guard self.generation == revision else {
                            self.operationStatus = "Документ изменился: выполните поиск заново"; self.updateState(); NSSound.beep(); return
                        }
                        self.select(range); self.window?.makeKeyAndOrderFront(nil); self.window?.makeFirstResponder(self.textView)
                    }
                    results.showWindow(nil)
                case .failure(let error): self.showError("Поиск не выполнен", error)
                }
                self.updateState()
            }
        }
    }

    private func find(_ query: EditorSearchQuery, direction: ViewerSearchDirection) {
        let text = textView.string, selection = textView.selectedRange(), revision = generation
        searchGeneration += 1; let request = searchGeneration
        var start = direction == .forward ? NSMaxRange(selection) : selection.location
        if direction == .forward, selection.length == 0, lastFoundRange == selection, lastFoundQuery == query { start += 1 }
        searchPending = true; operationStatus = "Поиск… (Esc — отменить)"; updateState()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<NSRange?, Error> = Result {
                if start > text.utf16.count { return nil }
                return try EditorEditing.find(in: text, query: query, from: start, direction: direction)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, self.generation == revision, self.searchGeneration == request else { return }
                self.searchPending = false
                switch result {
                case .success(let range):
                    if let range { self.select(range); self.lastFoundRange = range; self.lastFoundQuery = query; self.operationStatus = "Совпадение" }
                    else { self.operationStatus = "Совпадений в этом направлении больше нет"; NSSound.beep() }
                case .failure(let error): self.showError("Ошибка поиска", error); self.operationStatus = "Поиск остановлен"
                }
                self.updateState(); self.window?.makeFirstResponder(self.textView)
            }
        }
    }

    private func performReplacement(query: EditorSearchQuery, replacement: String, direction: ViewerSearchDirection,
                                    from origin: Int? = nil, replaced: Int = 0) {
        let text = textView.string, selection = textView.selectedRange(), revision = generation
        let start = origin ?? (direction == .forward ? selection.location : NSMaxRange(selection))
        searchGeneration += 1; let request = searchGeneration
        searchPending = true; operationStatus = "Замена… (Esc — отменить)"; updateState()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<(NSRange, EditorEdit)?, Error> = Result {
                guard start <= text.utf16.count else { return nil }
                guard let range = try EditorEditing.find(in: text, query: query, from: start, direction: direction) else { return nil }
                let updated = try EditorEditing.replace(in: text, range: range, query: query, replacement: replacement)
                let addedLength = updated.utf16.count - text.utf16.count + range.length
                return (range, EditorEdit(text: updated, selection: NSRange(location: range.location, length: addedLength), count: 1,
                                          changes: [EditorTextChange(range: range, replacementUTF16Length: addedLength)]))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, self.generation == revision, self.searchGeneration == request else { return }
                self.searchPending = false
                switch result {
                case .success(let match):
                    if let (range, edit) = match {
                        self.confirmReplacement(query: query, replacement: replacement, range: range, edit: edit,
                                                direction: direction, replaced: replaced, revision: revision)
                        return
                    }
                    self.operationStatus = replaced > 0 ? "Замен: \(replaced)" : "Совпадений больше нет"
                case .failure(let error): self.showError("Замена не выполнена", error); self.operationStatus = "Замена остановлена"
                }
                self.updateState(); self.window?.makeFirstResponder(self.textView)
            }
        }
    }

    private func confirmReplacement(query: EditorSearchQuery, replacement: String, range: NSRange, edit: EditorEdit,
                                    direction: ViewerSearchDirection, replaced: Int, revision: Int) {
        select(range)
        lastFoundRange = range; lastFoundQuery = query
        let found = (textView.string as NSString).substring(with: range)
        let inserted = (edit.text as NSString).substring(with: edit.selection)
        let alert = NSAlert()
        alert.messageText = "Подтвердить замену"
        alert.informativeText = "«\(found.prefix(120))» → «\(inserted.prefix(120))»"
        alert.addButton(withTitle: "Заменить")
        alert.addButton(withTitle: "Заменить все оставшиеся")
        alert.addButton(withTitle: "Пропустить")
        alert.addButton(withTitle: "Отмена").keyEquivalent = "\u{1b}"
        let answer = alert.runModal()
        guard !closed, generation == revision else { return }
        let forward = direction == .forward
        switch answer {
        case .alertFirstButtonReturn:
            guard withinBufferLimit(edit.text) else { showError("Замена не выполнена", EditorError.tooLarge); return }
            apply(edit, action: "Заменить")
            let origin = forward ? NSMaxRange(edit.selection) + (range.length == 0 ? 1 : 0) : range.location
            performReplacement(query: query, replacement: replacement, direction: direction, from: origin, replaced: replaced + 1)
        case .alertSecondButtonReturn:
            replaceRemaining(query: query, replacement: replacement, from: range.location + (forward ? 0 : 1),
                             direction: direction, replaced: replaced)
        case .alertThirdButtonReturn:
            let origin = forward ? NSMaxRange(range) + (range.length == 0 ? 1 : 0) : range.location
            performReplacement(query: query, replacement: replacement, direction: direction, from: origin, replaced: replaced)
        default:
            operationStatus = replaced > 0 ? "Замен: \(replaced)" : "Замена отменена"
            updateState(); window?.makeFirstResponder(textView)
        }
    }

    private func replaceRemaining(query: EditorSearchQuery, replacement: String, from: Int,
                                  direction: ViewerSearchDirection, replaced: Int) {
        let text = textView.string, revision = generation
        searchGeneration += 1; let request = searchGeneration
        searchPending = true; operationStatus = "Замена… (Esc — отменить)"; updateState()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try EditorEditing.replaceAll(in: text, query: query, replacement: replacement, from: from, direction: direction) }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, self.generation == revision, self.searchGeneration == request else { return }
                self.searchPending = false
                do {
                    let edit = try result.get()
                    guard self.withinBufferLimit(edit.text) else { throw EditorError.tooLarge }
                    if edit.count > 0 { self.apply(edit, action: "Заменить все оставшиеся") }
                    self.operationStatus = "Замен: \(replaced + edit.count)"
                } catch {
                    self.operationStatus = "Замена остановлена"
                    self.showError("Замена не выполнена", error)
                }
                self.updateState(); self.window?.makeFirstResponder(self.textView)
            }
        }
    }

    private func apply(_ edit: EditorEdit, action: String) {
        guard editable else { return }
        replaceBuffer(edit.text, selection: edit.selection, action: action, bookmarkChanges: edit.changes)
    }
    private func replaceBuffer(_ text: String, selection: NSRange, action: String, bookmarkChanges: [EditorTextChange]? = nil) {
        guard text != textView.string else { select(selection); return }
        // Keep temporarily unrepresentable characters editable: Save As can
        // select Unicode, and recovery still preserves the complete draft.
        guard withinBufferLimit(text) else { showError("Изменение не выполнено", EditorError.tooLarge); return }
        let manager = textView.undoManager
        textView.breakUndoCoalescing(); manager?.beginUndoGrouping()
        let full = NSRange(location: 0, length: textView.string.utf16.count)
        if textView.shouldChangeText(in: full, replacementString: text) {
            pendingBookmarkChanges = bookmarkChanges ?? EditorTextChange.difference(from: textView.string, to: text).map { [$0] }
            textView.replaceCharacters(in: full, with: text); textView.didChangeText()
            manager?.setActionName(action)
        }
        manager?.endUndoGrouping(); textView.breakUndoCoalescing(); select(selection)
    }

    @objc func gotoDocument(_ sender: Any?) {
        let value = field("", placeholder: "Строка:столбец, +10:-2, 50%, 0x20, $10, 20h")
        let hex = NSButton(checkboxWithTitle: "16-ричные значения без префикса", target: nil, action: nil)
        let alert = NSAlert(); alert.messageText = "Перейти к строке и столбцу"
        alert.informativeText = "С 1; +/− относительно курсора; % от числа строк / длины строки. Разделители: пробел , . ; : . Пустая координата сохраняется. Суффикс m — десятичное, h — hex."
        let stack = NSStackView(views: [value, hex]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 460, height: 65)
        alert.accessoryView = stack; alert.addButton(withTitle: "Перейти"); alert.addButton(withTitle: "Отмена")
        alert.window.initialFirstResponder = value
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let offset = try EditorEditing.gotoOffset(in: textView.string, expression: value.stringValue,
                from: textView.selectedRange().location, hexadecimal: hex.state == .on)
            select(NSRange(location: offset, length: 0)); window?.makeFirstResponder(textView)
        } catch { showError("Позиция недоступна", error) }
    }

    private func setBookmark(_ slot: Int) {
        bookmarks.set(slot: slot, offset: textView.selectedRange().location)
        operationStatus = "Закладка \(slot) установлена"; updateState()
    }
    private func gotoBookmark(_ slot: Int) {
        guard let offset = bookmarks.offset(slot: slot) else { NSSound.beep(); return }
        select(NSRange(location: min(offset, textView.string.utf16.count), length: 0))
        window?.makeFirstResponder(textView)
    }
    @objc private func bookmarksDocument(_ sender: Any?) {
        let popup = NSPopUpButton()
        for slot in 0...9 {
            let detail: String
            if let offset = bookmarks.offset(slot: slot) {
                let position = EditorEditing.lineColumn(in: textView.string, offset: offset)
                detail = "строка \(position.line), столбец \(position.column)"
            } else { detail = "не установлена" }
            popup.addItem(withTitle: "\(slot) — \(detail)")
        }
        popup.frame = NSRect(x: 0, y: 0, width: 360, height: 28)
        let alert = NSAlert(); alert.messageText = "Закладки редактора"
        alert.informativeText = "Ctrl+Shift+0…9 — установить; Ctrl+0…9 — перейти. Закладки следуют за правками; сохраняются при закрытии сохранённого локального документа."
        alert.accessoryView = popup; alert.addButton(withTitle: "Перейти"); alert.addButton(withTitle: "Установить"); alert.addButton(withTitle: "Удалить"); alert.addButton(withTitle: "Отмена")
        let response = alert.runModal(), slot = popup.indexOfSelectedItem
        if response == .alertFirstButtonReturn { gotoBookmark(slot) }
        else if response == .alertSecondButtonReturn { setBookmark(slot) }
        else if response == .alertThirdButtonReturn { bookmarks.remove(slot: slot) }
    }

    @objc private func tabsChanged(_ sender: Any?) {
        tabSize = [2, 4, 8][max(0, tabsPopup.indexOfSelectedItem)]; useSpaces = spacesCheck.state == .on; configureTabs()
    }
    private func configureTabs() {
        textView.tabSize = tabSize; textView.usesSpaces = useSpaces
        let paragraph = NSMutableParagraphStyle(); paragraph.tabStops = []
        let width = (" " as NSString).size(withAttributes: [.font: textView.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]).width
        paragraph.defaultTabInterval = width * CGFloat(tabSize)
        textView.defaultParagraphStyle = paragraph
        textView.textStorage?.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: textView.string.utf16.count))
    }
    private func indent(outdent: Bool) {
        guard editable else { return }
        do {
            apply(try EditorEditing.indent(in: textView.string, selection: textView.selectedRange(), tabSize: tabSize, useSpaces: useSpaces, outdent: outdent), action: outdent ? "Убрать отступ" : "Отступ")
        } catch { showError("Не удалось изменить отступ", error) }
    }
    @objc private func toggleLineNumbers(_ sender: Any?) { scroll.rulersVisible.toggle() }

    @objc private func blockDocument(_ sender: Any?) {
        guard editable else { return }
        let position = EditorEditing.lineColumn(in: textView.string, offset: textView.selectedRange().location)
        let source = textView.string as NSString
        let caret = textView.selectedRange().location
        let start = source.lineRange(for: NSRange(location: caret, length: 0)).location
        let prefix = source.substring(with: NSRange(location: start, length: caret - start))
        var visualColumn = 1
        for character in prefix {
            visualColumn += character == "\t" ? tabSize - (visualColumn - 1) % tabSize : 1
        }
        let firstLine = field("\(rectangle?.firstLine ?? position.line)")
        let lastLine = field("\(rectangle?.lastLine ?? position.line)")
        let firstColumn = field("\(rectangle?.firstColumn ?? visualColumn)")
        let lastColumn = field("\(rectangle?.lastColumn ?? visualColumn + 1)")
        let operation = NSPopUpButton(); operation.addItems(withTitles: ["Копировать", "Вырезать", "Вставить из буфера"])
        let stack = NSStackView(views: [row("От строки", firstLine), row("До строки", lastLine), row("От столбца", firstColumn), row("До столбца", lastColumn), row("Действие", operation)])
        stack.orientation = .vertical; stack.spacing = 8; stack.frame = NSRect(x: 0, y: 0, width: 430, height: 190)
        let alert = NSAlert(); alert.messageText = "Прямоугольный блок"
        alert.informativeText = "Строки включительно; конечный столбец не входит в блок. Табуляция учитывается по выбранной ширине. Для вставки без удаления задайте одинаковые столбцы."
        alert.accessoryView = stack; alert.addButton(withTitle: "Выполнить"); alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let block = EditorRectangle(firstLine: Int(firstLine.stringValue) ?? 0, lastLine: Int(lastLine.stringValue) ?? 0,
                                    firstColumn: Int(firstColumn.stringValue) ?? 0, lastColumn: Int(lastColumn.stringValue) ?? 0)
        do {
            guard block.firstLine > 0, block.lastLine >= block.firstLine, block.firstColumn > 0, block.lastColumn >= block.firstColumn else {
                throw NSError(domain: "Editor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Введите положительные номера; конец блока должен быть после начала."])
            }
            _ = try EditorEditing.offset(in: textView.string, line: block.lastLine)
            rectangle = block
            switch operation.indexOfSelectedItem {
            case 0, 1:
                let copied = try EditorEditing.extractRectangle(in: textView.string, rectangle: block, tabSize: tabSize)
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(copied, forType: .string)
                if operation.indexOfSelectedItem == 1 {
                    apply(try EditorEditing.replaceRectangle(in: textView.string, rectangle: block, replacement: "", tabSize: tabSize), action: "Вырезать блок")
                }
            default:
                guard let pasted = NSPasteboard.general.string(forType: .string) else { NSSound.beep(); return }
                apply(try EditorEditing.replaceRectangle(in: textView.string, rectangle: block, replacement: pasted, tabSize: tabSize), action: "Вставить блок")
            }
            operationStatus = "Прямоугольный блок: \(block.firstLine)…\(block.lastLine), \(block.firstColumn)…\(block.lastColumn)"; updateState()
        } catch { showError("Блок недоступен", error) }
        window?.makeFirstResponder(textView)
    }

    @objc private func syntaxChanged(_ sender: Any?) {
        switch syntaxPopup.indexOfSelectedItem {
        case 0: selectedSyntax = nil
        case 1: selectedSyntax = "none"
        default: selectedSyntax = EditorSyntaxRegistry.providers[syntaxPopup.indexOfSelectedItem - 2].id
        }
        scheduleHighlight()
    }
    private func scheduleHighlight() {
        highlightWork?.cancel(); highlightGeneration += 1
        let request = highlightGeneration
        let text = textView.string, revision = generation
        syntaxSpans.removeAll()
        luaPaintColorLayers()
        guard text.utf8.count <= 256 * 1024, selectedSyntax != "none" else { return }
        let provider: (any EditorSyntaxProvider)?
        if let selectedSyntax { provider = EditorSyntaxRegistry.providers.first { $0.id == selectedSyntax } }
        else { provider = EditorSyntaxRegistry.provider(for: sourceURL?.lastPathComponent ?? "") }
        guard let provider else { return }
        let work = DispatchWorkItem { [weak self] in
            let spans = provider.highlights(text: text)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == revision, self.highlightGeneration == request else { return }
                self.syntaxSpans = spans
                self.luaPaintColorLayers()
            }
        }
        highlightWork = work; DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags.isEmpty, event.keyCode == 103 { FarLuaPlugins.shared.showMenu(); return true }
        if let bookmark = TextDocumentDialogs.bookmarkShortcut(event, flags: flags) {
            if bookmark.set { setBookmark(bookmark.slot) } else { gotoBookmark(bookmark.slot) }
            return true
        }
        if event.keyCode == 53, flags.isEmpty, searchPending {
            searchGeneration += 1; searchPending = false; operationStatus = "Поиск / замена отменены"; updateState(); return true
        }
        if flags == .command {
            // Keep editor commands available with a non-Latin input source.
            switch event.keyCode {
            case 3: findDocument(nil); return true // physical F
            case 37: gotoDocument(nil); return true // physical L
            default: break
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "f": findDocument(nil); return true
            case "l": gotoDocument(nil); return true
            default: break
            }
        }
        if flags == [.command, .option], event.keyCode == 3 || event.charactersIgnoringModifiers?.lowercased() == "f" { replaceDocument(nil); return true }
        if event.keyCode == 6, flags == .control || flags == [.control, .shift] {
            guard editable else { NSSound.beep(); return true }
            if flags.contains(.shift) {
                if textView.undoManager?.canRedo == true { textView.undoManager?.redo() } else { NSSound.beep() }
            } else {
                if textView.undoManager?.canUndo == true { textView.undoManager?.undo() } else { NSSound.beep() }
            }
            return true
        }
        if flags == .option {
            switch event.keyCode {
            case 34: indent(outdent: false); return true // physical I
            case 32: indent(outdent: true); return true // physical U
            default: break
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "i": indent(outdent: false); return true
            case "u": indent(outdent: true); return true
            default: break
            }
        }
        switch (event.keyCode, flags) {
        case (120, []): saveDocument(nil) // F2
        case (120, .shift): saveAsDocument(nil)
        case (98, []): findDocument(nil) // F7
        case (98, .control): replaceDocument(nil)
        case (98, .shift): continueSearch(direction: .forward)
        case (98, .option): continueSearch(direction: .backward)
        case (100, .option): gotoDocument(nil) // F8
        case (100, []): changeCodePage(TextDocumentDialogs.nextCodePage(after: format.encoding))
        case (100, .shift): selectCodePage()
        case (99, .control): toggleLineNumbers(nil) // F3
        case (97, []): switchToViewer(nil) // F6
        case (109, .shift): if save() { window?.performClose(nil) } // Shift F10
        case (53, []), (109, []), (118, []): window?.performClose(nil) // Escape / F10 / F4
        default: return false
        }
        return true
    }
}

extension TextFileWindow {
    static func registerAutomation(in workspace: CommandWorkspace) {
        for (id, title, select, direction) in [
            ("editor.brackets.findForward", "Парные скобки: найти вперёд", false, EditorBrackets.Direction.forward),
            ("editor.brackets.findBackward", "Парные скобки: найти назад", false, .backward),
            ("editor.brackets.selectForward", "Парные скобки: выделить вперёд", true, .forward),
            ("editor.brackets.selectBackward", "Парные скобки: выделить назад", true, .backward)
        ] {
            workspace.register(id, title: title, contexts: [.editor], recordable: true) {
                guard let editor = NSApp.keyWindow?.windowController as? TextFileWindow, !editor.closed else { throw CommandRegistryError.contextMismatch }
                editor.performBrackets(select: select, direction: direction)
            }
        }

        for (id, title) in [("editor.indent", "Увеличить отступ"), ("editor.outdent", "Уменьшить отступ"), ("editor.lineNumbers", "Номера строк"), ("editor.selectAll", "Выделить весь текст")] {
            workspace.register(id, title: title, contexts: [.editor], recordable: true) {
                guard let editor = NSApp.keyWindow?.windowController as? TextFileWindow, !editor.closed else { throw CommandRegistryError.contextMismatch }
                switch id {
                case "editor.indent", "editor.outdent":
                    guard editor.editable else { throw CommandRegistryError.contextMismatch }
                    let edit = try EditorEditing.indent(in: editor.textView.string, selection: editor.textView.selectedRange(), tabSize: editor.tabSize, useSpaces: editor.useSpaces, outdent: id == "editor.outdent")
                    guard editor.withinBufferLimit(edit.text) else { throw EditorError.tooLarge }
                    editor.apply(edit, action: title)
                case "editor.lineNumbers": editor.toggleLineNumbers(nil)
                default: editor.textView.selectAll(nil)
                }
            }
        }
        for (id, title) in [("editor.save", "Сохранить документ"), ("editor.find", "Найти в документе"), ("editor.replace", "Заменить в документе"), ("editor.goto", "Перейти к строке")] {
            workspace.register(id, title: title, contexts: [.editor]) {
                guard let editor = NSApp.keyWindow?.windowController as? TextFileWindow else { throw CommandRegistryError.contextMismatch }
                switch id {
                case "editor.save": editor.saveDocument(nil)
                case "editor.find": editor.findDocument(nil)
                case "editor.replace": editor.replaceDocument(nil)
                default: editor.gotoDocument(nil)
                }
            }
        }
    }
    func automationKey(_ event: NSEvent) -> String? {
        guard window?.firstResponder === textView else { return nil }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if (flags == [.control] || flags == [.control, .shift]), [33, 30].contains(event.keyCode), !textView.hasMarkedText() {
            return "editor.brackets." + (flags.contains(.shift) ? "select" : "find") + (event.keyCode == 33 ? "Forward" : "Backward")
        }
        if flags == [.option], event.keyCode == 34 { return "editor.indent" }
        if flags == [.option], event.keyCode == 32 { return "editor.outdent" }
        if flags == [.control], event.keyCode == 99 { return "editor.lineNumbers" }
        if flags == [.command], event.keyCode == 0 { return "editor.selectAll" }
        return nil
    }
    var extensionText: String { textView.string }
    var extensionSelection: NSRange { textView.selectedRange() }
    var extensionTabSize: Int { tabSize }
    var extensionRevision: Int { generation }
    func applyExtensionText(_ text: String, revision: Int, title: String) throws {
        guard !closed, editable, generation == revision, window?.isVisible == true else { throw ExtensionAPIError("Документ изменился или закрыт. Повторите запуск расширения.") }
        guard withinBufferLimit(text) else { throw EditorError.tooLarge }
        replaceBuffer(text, selection: NSRange(location: 0, length: 0), action: title)
    }
}

extension TextFileWindow {
    static func runEditingUISmokeChecks() throws -> [String] {
        let editor = TextFileWindow(newIn: AppRuntime.smokeDirectory ?? FileManager.default.temporaryDirectory)
        defer { editor.pendingDiscard = true; editor.finalizeClose(); editor.window?.close() }
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw NSError(domain: "EditorSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        editor.showWindow(nil)
        editor.replaceBuffer("one\r\n🙂two\nlast", selection: NSRange(location: 8, length: 0), action: "Smoke")
        let set = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .shift], timestamp: 0,
            windowNumber: editor.window?.windowNumber ?? 0, context: nil, characters: "!", charactersIgnoringModifiers: "!", isARepeat: false, keyCode: 18)!
        try require(editor.handleKey(set), "Editor handles Ctrl Shift digit")
        try require(editor.bookmarks.offset(slot: 1) == 8, "Numbered bookmark records editor caret")
        editor.select(NSRange(location: 0, length: 0))
        let go = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0,
            windowNumber: editor.window?.windowNumber ?? 0, context: nil, characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18)!
        try require(editor.handleKey(go), "Editor handles Ctrl digit")
        try require(editor.textView.selectedRange().location == 8, "Numbered bookmark moves editor caret")
        editor.replaceBuffer("prefix one\r\n🙂two\nlast", selection: NSRange(location: 0, length: 0), action: "Smoke")
        try require(editor.bookmarks.offset(slot: 1) == 15, "Bookmark follows editor buffer edit")
        let matches = try EditorEditing.allMatches(in: editor.textView.string, query: .init(pattern: "two"))
        try require(matches.matches.count == 1 && matches.matches[0].line == 2, "All matches use editor buffer positions")
        editor.replaceBuffer("cat KEEP cat", selection: NSRange(location: 4, length: 0), action: "Smoke")
        editor.bookmarks = EditorBookmarks(); editor.setBookmark(1)
        let replaced = try EditorEditing.replaceAll(in: editor.textView.string, query: .init(pattern: "cat"), replacement: "dog")
        editor.apply(replaced, action: "Smoke")
        try require(editor.bookmarks.offset(slot: 1) == 4, "Disjoint replacement preserves untouched editor bookmark")
        let options = EditorSearchOptionsControls(query: .init(pattern: "resume", fuzzy: true))
        try require(options.fuzzy.state == .on && options.regex.state == .off, "Editor fuzzy checkbox restores query")
        options.style.performClick(nil)
        try require(options.style.state == .on && options.fuzzy.state == .off, "Editor style and fuzzy modes are exclusive")
        options.regex.performClick(nil)
        try require(options.regex.state == .on && options.style.state == .off, "Editor regex and style modes are exclusive")
        editor.replaceBuffer("🙂résumé RÉSUMÉ", selection: NSRange(location: 0, length: 0), action: "Smoke")
        let fuzzyQuery = EditorSearchQuery(pattern: "resume", fuzzy: true)
        let fuzzyMatches = try EditorEditing.allMatches(in: editor.textView.string, query: fuzzyQuery)
        try require(fuzzyMatches.matches.count == 2 && fuzzyMatches.matches[0].range == NSRange(location: 2, length: 8), "Editor fuzzy results select original decomposed accents")
        editor.select(fuzzyMatches.matches[0].range)
        try require(editor.textView.selectedRange() == fuzzyMatches.matches[0].range, "AppKit highlights original fuzzy range")
        editor.replaceBuffer("UserName USER_NAME user-name", selection: NSRange(location: 0, length: 0), action: "Smoke")
        editor.textView.undoManager?.removeAllActions()
        let styleEdit = try EditorEditing.replaceAll(in: editor.textView.string, query: .init(pattern: "user_name", preserveStyle: true), replacement: "account_id")
        editor.apply(styleEdit, action: "Сохранить стиль")
        try require(editor.textView.string == "AccountId ACCOUNT_ID account-id", "AppKit applies style replacement across identifier separators")
        try require(editor.textView.selectedRange() == styleEdit.selection, "AppKit selects final styled replacement")
        editor.textView.undoManager?.undo()
        try require(editor.textView.string == "UserName USER_NAME user-name", "Styled replace all is one undo action")
        editor.textView.undoManager?.redo()
        try require(editor.textView.string == styleEdit.text, "Styled replace all supports redo")
        let path = editor.initialDirectory.appendingPathComponent("editor-named-\(UUID().uuidString).txt")
        let named = TextFileWindow(newAt: path, encoding: .utf8)
        defer { named.window?.close(); try? FileManager.default.removeItem(at: path) }
        try require(named.window?.representedURL == path && !FileManager.default.fileExists(atPath: path.path),
                    "Named editor waits until F2 to create the file")
        named.replaceBuffer("first\nsecond", selection: NSRange(location: 0, length: 0), action: "Smoke")
        try require(named.save(), "F2 saves a named editor buffer without a second dialog")
        let bytes = try Data(contentsOf: path)
        try require(bytes == Data([0xEF, 0xBB, 0xBF] + Array("first\r\nsecond".utf8)), "Named Unicode editor writes BOM and CRLF")
        return ["Editor numbered bookmark shortcuts", "Editor bookmark follows buffer edit", "Editor all-match positions", "Editor fuzzy and style options", "Editor fuzzy original-range highlight", "Editor styled replacement undo redo", "Editor named creation and first save"] + (try EditorSearchResultsWindow.runUISmokeChecks())
    }
}


extension TextFileWindow {
    func performBrackets(select: Bool, direction: EditorBrackets.Direction?) {
        guard !closed else { return }
        let options = BracketsWorkspace.options
        let cursor = textView.selectedRange().location
        var result = EditorBrackets.find(in: textView.string, cursor: cursor, direction: direction, options: options)
        if result == .needsDirection {
            guard let chosen = BracketsWorkspace.direction(owner: window) else { return }
            result = EditorBrackets.find(in: textView.string, cursor: cursor, direction: chosen, options: options)
        }
        guard case let .match(match) = result else { return }
        textView.setSelectedRange(select ? match.selection : NSRange(location: match.target, length: 0))
        textView.scrollRangeToVisible(NSRange(location: match.target, length: 0))
        if BracketsWorkspace.options.beep { NSSound.beep() }
        updateState()
    }

    static func runBracketsUISmokeChecks() throws -> [String] {
        let previous = BracketsWorkspace.options
        BracketsWorkspace.options = .init()
        defer { BracketsWorkspace.options = previous }
        let editor = TextFileWindow(newIn: AppRuntime.smokeDirectory ?? FileManager.default.temporaryDirectory)
        editor.showWindow(nil)
        defer { editor.closeArchiveWorkingCopyWithoutSaving() }
        let original = "🙂{one\n{two}} tail"
        editor.textView.string = original
        editor.textView.setSelectedRange(NSRange(location: 2, length: 0))
        editor.performBrackets(select: true, direction: .forward)
        let selected = (original as NSString).substring(with: editor.textView.selectedRange())
        guard selected == "{one\n{two}}", editor.textView.string == original else { throw ExtensionAPIError("Brackets must select the full nested block without modifying text.") }
        editor.textView.setSelectedRange(NSRange(location: 2, length: 0))
        editor.performBrackets(select: false, direction: .backward)
        guard editor.textView.selectedRange() == NSRange(location: 12, length: 0) else { throw ExtensionAPIError("Brackets navigation must follow the opening bracket, regardless of explicit quote direction.") }
        editor.textView.setSelectedRange(NSRange(location: 15, length: 2))
        editor.performBrackets(select: true, direction: .forward)
        guard editor.textView.selectedRange() == NSRange(location: 15, length: 2), editor.textView.string == original else { throw ExtensionAPIError("Failed Brackets lookup must preserve selection and text.") }
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .shift], timestamp: 0, windowNumber: editor.window!.windowNumber, context: nil, characters: "{", charactersIgnoringModifiers: "[", isARepeat: false, keyCode: 33)!
        editor.window?.makeFirstResponder(editor.textView)
        guard editor.automationKey(event) == "editor.brackets.selectForward" else { throw ExtensionAPIError("Brackets shortcut must use the editor command registry.") }
        return ["Brackets selects nested Unicode multiline block without edits", "Brackets direction follows pair and failed lookup preserves selection", "Brackets Ctrl Shift [ routes to recordable editor command"]
    }
}

// The LuaFar ABI uses 1-based UTF-16 offsets. AppKit keeps a selection separate
// from the script's logical caret only while a Lua block is active.
extension TextFileWindow {
    var luaDocumentIsClosed: Bool { closed }
    var luaFileWasSaved: Bool { luaWasSaved }

    func luaConfigureOpen(title: String?, startLine: Int = -1, startColumn: Int = -1, savePosition: Bool = true) {
        luaTitle = title
        luaAllowPositionHistory = savePosition
        if startLine >= 0 {
            let coordinates = luaCoordinates()
            let row = min(coordinates.lines.count, max(1, startLine))
            let line = coordinates.lines[row - 1].text
            let text = textView.string as NSString
            let column = luaRealColumn(max(1, startColumn), in: text.substring(with: line))
            var offset = line.location + min(line.length, column - 1)
            if offset < text.length, Range(NSRange(location: offset, length: 0), in: textView.string) == nil {
                offset = text.rangeOfComposedCharacterSequence(at: offset).location
            }
            select(NSRange(location: offset, length: 0))
        }
        updateState()
    }

    func luaDiscardForReopen() {
        luaAllowPositionHistory = false
        pendingDiscard = true
        window?.close()
    }

    private var luaEditorFilename: String { workingCopyDisplayPath ?? sourceURL?.path ?? "" }
    private var luaEditorID: FarLuaValue { .hostInteger(window?.windowNumber ?? -1) }
    private var luaEditorState: Int { (luaWasSaved ? 1 : 0) | (isDirty ? 0 : 2) | (editable ? 0 : 4) }

    private func luaCoordinates() -> FarEditorCoordinates {
        if luaCoordinateGeneration == generation, let luaCoordinateCache { return luaCoordinateCache }
        let coordinates = FarEditorCoordinates(textView.string)
        luaCoordinateCache = coordinates
        luaCoordinateGeneration = generation
        return coordinates
    }

    var luaEditorProperties: FarLuaValue {
        let text = textView.string as NSString
        let coordinates = luaCoordinates()
        let caret = luaCaret ?? textView.selectedRange().location
        let position = coordinates.position(caret)
        let line = text.substring(with: coordinates.lines[position.line - 1].text)
        let selected: String
        if let block = luaRectangle {
            selected = (try? EditorEditing.extractRectangle(in: textView.string, rectangle: block, tabSize: tabSize)) ?? ""
        } else {
            selected = text.substring(with: luaStream ?? textView.selectedRange())
        }
        return .table(["CurLine": .hostInteger(position.line), "CurPos": .hostInteger(luaVisualColumn(position.column, in: line)),
            "RealPos": .hostInteger(position.column), "Lines": .hostInteger(coordinates.lines.count),
            "FileName": .string(luaEditorFilename), "SelValue": .string(selected), "Selected": .bool(luaRectangle != nil || !selected.isEmpty),
            "Value": .string(line), "State": .hostInteger(luaEditorState)])
    }

    private func luaEditorEvent(_ event: Int, _ parameter: FarLuaValue = .integer(0)) {
        guard luaReadSent else { return }
        FarLuaWorkspace.shared.event("EditorEvent", [luaEditorID, .hostInteger(event), parameter])
    }

    private func luaEditorChanged(from previous: String, to text: String) {
        guard luaReadSent, FarLuaWorkspace.shared.hasEventHandlers("EditorEvent"),
              let change = EditorTextChange.difference(from: previous, to: text) else { return }
        let before = FarEditorCoordinates(previous), after = FarEditorCoordinates(text)
        let start = before.position(change.range.location).line
        let end = after.position(change.range.location + change.replacementUTF16Length).line
        let delta = after.lines.count - before.lines.count
        func changed(_ type: Int, _ line: Int) {
            luaEditorEvent(8, .table(["Type": .hostInteger(type), "StringNumber": .hostInteger(line)]))
        }
        for index in 0..<min(128, max(1, end - start + 1 - max(0, delta))) { changed(0, start + index) }
        if delta > 0 {
            for index in 0..<min(128, delta) { changed(1, start + index + 1) }
        } else if delta < 0 {
            for _ in 0..<min(128, -delta) { changed(2, start + 1) }
        }
    }

    private static func luaCodePage(_ encoding: ViewerEncoding) -> Int {
        switch encoding {
        case .automatic, .utf8: return 65001
        case .utf16LE: return 1200
        case .utf16BE: return 1201
        case .windows1251: return 1251
        case .windows1252: return 1252
        case .latin1: return 28591
        case .dos437: return 437
        case .dos866: return 866
        }
    }

    private func luaSaveFile(_ args: [FarLuaValue]) -> Bool {
        guard editable else { return false }
        let name = args.lua(1).hostString
        let destination: URL
        if let name {
            guard !name.isEmpty, !name.utf8.contains(0) else { return false }
            destination = (name.hasPrefix("/") ? URL(fileURLWithPath: name) : initialDirectory.appendingPathComponent(name)).standardizedFileURL
        } else {
            guard let sourceURL else { return false }
            destination = sourceURL.standardizedFileURL
        }
        // Alternate paths are local Save As operations. A provider working copy
        // must stay bound to the archive entry or remote path opened by the app.
        let samePath = destination == sourceURL?.standardizedFileURL
        if !samePath, retainedArchiveWorkspace != nil || retainedRemoteWorkspace != nil { return false }
        if samePath, recoveredDraft, snapshot == nil { return false }
        var requested = format
        if let eol = args.lua(2).hostString {
            switch eol {
            case "": requested.lineEnding = .preserve
            case "\n": requested.lineEnding = .lf
            case "\r": requested.lineEnding = .cr
            case "\r\n": requested.lineEnding = .crlf
            default: return false
            }
        }
        if let codePage = args.lua(3).hostInt, codePage != -1 {
            let target: ViewerEncoding?
            if codePage == 0 || codePage == 1 { target = TextDocumentDialogs.systemCodePages[codePage] }
            else { target = ViewerEncoding.allCases.first { $0 != .automatic && Self.luaCodePage($0) == codePage } }
            guard let target else { return false }
            requested.encoding = target
            if ![.utf8, .utf16LE, .utf16BE].contains(target) { requested.bom = false }
        }
        do {
            let expected: EditorSnapshot?
            if samePath {
                expected = snapshot
            } else if FileManager.default.fileExists(atPath: destination.path) {
                let existing: EditorSnapshot
                do { existing = try EditorDocument.load(url: destination, encoding: .automatic) }
                catch { existing = try EditorDocument.load(url: destination, encoding: requested.encoding) }
                let alert = NSAlert()
                alert.messageText = "Заменить файл «\(destination.lastPathComponent)»?"
                alert.informativeText = destination.path
                alert.addButton(withTitle: "Отмена")
                alert.addButton(withTitle: "Заменить")
                guard alert.runModal() == .alertSecondButtonReturn else { return false }
                expected = existing
            } else {
                expected = nil
            }
            let result = try EditorDocument.save(text: textView.string, format: requested, to: destination, expected: expected)
            didSave(result)
            return true
        } catch {
            operationStatus = error.localizedDescription
            updateState()
            return false
        }
    }

    private func luaVisualColumn(_ column: Int, in line: String) -> Int {
        let wanted = max(0, min(EditorEditing.maximumRectangleCoordinate, column - 1))
        var real = 0, visual = 0
        for character in line {
            guard real < wanted else { break }
            real += character.utf16.count
            visual += character == "\t" ? tabSize - visual % tabSize : 1
        }
        return visual + max(0, wanted - real) + 1
    }

    private func luaRealColumn(_ column: Int, in line: String) -> Int {
        let wanted = max(0, min(EditorEditing.maximumRectangleCoordinate, column - 1))
        var real = 0, visual = 0
        for character in line {
            let width = character == "\t" ? tabSize - visual % tabSize : 1
            if visual + width > wanted { return real + 1 }
            real += character.utf16.count
            visual += width
        }
        return real + max(0, wanted - visual) + 1
    }

    private var luaCellSize: NSSize {
        let font = textView.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        let width = max(1, ("M" as NSString).size(withAttributes: [.font: font]).width)
        return NSSize(width: width, height: max(1, textView.layoutManager?.defaultLineHeight(for: font) ?? 16))
    }

    private func luaTopLine(_ coordinates: FarEditorCoordinates) -> Int {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return 1 }
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        guard glyphs.length > 0 else { return 1 }
        return coordinates.position(layout.characterIndexForGlyph(at: glyphs.location)).line
    }

    private func luaEditorInfo(_ coordinates: FarEditorCoordinates, position: (line: Int, column: Int), line: String,
                               blockType: Int, blockStart: Int) -> [String: FarLuaValue] {
        let cell = luaCellSize, visible = scroll.contentSize
        let columns = max(1, Int(visible.width / cell.width))
        let rows = max(1, Int(visible.height / cell.height))
        let area: FarLuaValue = .table(["Left": .integer(0), "Top": .integer(0),
            "Right": .hostInteger(columns - 1), "Bottom": .hostInteger(rows - 1)])
        let options = (useSpaces ? 0x80 : 0) | (textView.autoIndentNewline ? 0x08 : 0) |
            (luaSavePosition ? 0x10 : 0) | (format.bom ? 0x200 : 0) | 0x800 | 0x1000 |
            (scroll.hasVerticalScroller ? 0x2000 : 0)
        return ["EditorID": luaEditorID, "FileName": .string(luaEditorFilename),
            "TotalLines": .hostInteger(coordinates.lines.count), "CurLine": .hostInteger(position.line), "CurPos": .hostInteger(position.column),
            "CurTabPos": .hostInteger(luaVisualColumn(position.column, in: line)), "TopScreenLine": .hostInteger(luaTopLine(coordinates)),
            "LeftPos": .hostInteger(max(1, Int(scroll.contentView.bounds.origin.x / cell.width) + 1)),
            "Overtype": .integer(textView.overtype ? 1 : 0), "BlockType": .hostInteger(blockType), "BlockStartLine": .hostInteger(blockStart),
            "TabSize": .hostInteger(tabSize), "CurState": .hostInteger(luaEditorState), "CodePage": .hostInteger(Self.luaCodePage(format.encoding)),
            "Options": .hostInteger(options), "BookmarkCount": .integer(10), "SessionBookmarkCount": .integer(0),
            "WindowSizeX": .hostInteger(columns), "WindowSizeY": .hostInteger(rows), "WindowArea": area, "ClientArea": area]
    }

    func luaFinishUndoGroups() {
        guard let manager = textView.undoManager else { luaUndoLevels.removeAll(); return }
        textView.breakUndoCoalescing()
        while let level = luaUndoLevels.last, level >= manager.groupingLevel {
            luaUndoLevels.removeLast()
            if level == manager.groupingLevel, level > 0 { manager.endUndoGrouping() }
        }
    }

    private func luaUndoRedo(_ command: Int) -> Bool {
        guard editable, let manager = textView.undoManager else { return false }
        textView.breakUndoCoalescing()
        switch command {
        case 0:
            guard luaUndoLevels.count < 64 else { return false }
            manager.beginUndoGrouping()
            luaUndoLevels.append(manager.groupingLevel)
        case 1:
            guard luaUndoLevels.last == manager.groupingLevel, manager.groupingLevel > 0 else { return false }
            luaUndoLevels.removeLast()
            manager.endUndoGrouping()
        case 2, 3:
            guard luaUndoLevels.isEmpty, manager.groupingLevel <= 1 else { return false }
            if command == 2, manager.canUndo { manager.undo() }
            if command == 3, manager.canRedo { manager.redo() }
        default: return false
        }
        return true
    }

    private func luaInstallSelection(caret: Int, stream: NSRange? = nil, rectangle: EditorRectangle? = nil,
                                     visibleRanges: [NSValue] = []) {
        installingLuaSelection = true
        defer { installingLuaSelection = false }
        luaCaret = caret; luaStream = stream; luaRectangle = rectangle
        if !visibleRanges.isEmpty { textView.selectedRanges = visibleRanges }
        else { textView.setSelectedRange(stream ?? NSRange(location: caret, length: 0)) }
        textView.scrollRangeToVisible(NSRange(location: caret, length: 0))
        updateState()
    }

    private func luaEditorSetting(_ args: [FarLuaValue]) -> FarLuaValue {
        let index = args.lua(0).hostInt ?? 0
        let value = args.lua(1).hostInt ?? args.lua(1).bool.map { $0 ? 1 : 0 } ?? -1
        let old: Int
        switch index {
        case 0:
            old = tabSize
            if value != -1 {
                guard (1...64).contains(value) else { return .integer(-1) }
                tabSize = value
                if let index = [2, 4, 8].firstIndex(of: value) { tabsPopup.selectItem(at: index) }
                configureTabs()
            }
        case 1:
            old = useSpaces ? 2 : 0
            if value != -1 {
                guard value == 0 || value == 2 else { return .integer(-1) }
                useSpaces = value == 2
                spacesCheck.state = useSpaces ? .on : .off
                configureTabs()
            }
        case 4:
            old = textView.autoIndentNewline ? 1 : 0
            if value != -1 { textView.autoIndentNewline = value != 0 }
        case 10:
            old = luaSavePosition ? 1 : 0
            if value != -1 { luaSavePosition = value != 0 }
        case 15:
            old = scroll.hasVerticalScroller ? 1 : 0
            if value != -1 { scroll.hasVerticalScroller = value != 0 }
        default: return .integer(-1)
        }
        return .hostInteger(old)
    }

    func luaEditorCall(_ name: String, _ args: [FarLuaValue]) throws -> [FarLuaValue] {
        guard !closed else { return [.nilValue] }
        let helper = name.hasPrefix("Editor.")
        if !helper, let id = args.lua(0).hostInt, id != -1, .hostInteger(id) != luaEditorID { return [.nilValue] }
        let text = textView.string, source = text as NSString, coordinates = luaCoordinates()
        let nativeSelection = textView.selectedRange()
        let stream = luaStream ?? (luaRectangle == nil && nativeSelection.length > 0 ? nativeSelection : nil)
        let caret = luaCaret ?? nativeSelection.location
        let position = coordinates.position(caret)
        let blockType = luaRectangle != nil ? 2 : stream == nil ? 0 : 1
        let blockStart = luaRectangle?.firstLine ?? stream.map { coordinates.position($0.location).line } ?? 1
        let lineText = source.substring(with: coordinates.lines[position.line - 1].text)
        let requestedLine = args.lua(1).hostInt ?? 0
        let lineNumber = requestedLine == 0 ? position.line : requestedLine
        let currentEOL = source.substring(with: coordinates.lines[position.line - 1].ending)
        let eol = currentEOL.isEmpty
            ? coordinates.lines.first(where: { $0.ending.length > 0 }).map { source.substring(with: $0.ending) }
                ?? (format.lineEnding == .crlf ? "\r\n" : format.lineEnding == .cr ? "\r" : "\n")
            : currentEOL

        func bool(_ success: Bool) -> [FarLuaValue] { [helper ? .integer(success ? 1 : 0) : .bool(success)] }
        func replace(_ range: NSRange, _ replacement: String, preserveCaret: Bool = false) -> Bool {
            guard editable, range.location >= 0, NSMaxRange(range) <= source.length, Range(range, in: text) != nil else { return false }
            let result = source.replacingCharacters(in: range, with: replacement)
            guard withinBufferLimit(result) else { return false }
            let offset: Int
            if preserveCaret {
                // Position is kept by line and column for ECTL_SETSTRING.
                let updated = FarEditorCoordinates(result)
                let row = min(position.line, updated.lines.count)
                offset = updated.lines[row - 1].text.location + min(position.column - 1, updated.lines[row - 1].text.length)
            } else {
                offset = min(result.utf16.count, range.location + replacement.utf16.count)
            }
            replaceBuffer(result, selection: NSRange(location: offset, length: 0), action: "LuaMacro",
                bookmarkChanges: [EditorTextChange(range: range, replacementUTF16Length: replacement.utf16.count)])
            return true
        }
        func deleteLine(_ row: Int) -> Bool {
            guard coordinates.lines.indices.contains(row - 1) else { return false }
            let line = coordinates.lines[row - 1]
            if row == coordinates.lines.count, row > 1 {
                let start = coordinates.lines[row - 2].ending.location
                return replace(NSRange(location: start, length: source.length - start), "", preserveCaret: true)
            }
            return replace(line.full, "", preserveCaret: true)
        }
        func move(_ values: [String: FarLuaValue]) -> Bool {
            let row = max(1, min(coordinates.lines.count, positive(values["CurLine"]) ?? position.line))
            let target = coordinates.lines[row - 1]
            let line = source.substring(with: target.text)
            let column: Int
            if let visual = positive(values["CurTabPos"]) { column = luaRealColumn(visual, in: line) }
            else { column = positive(values["CurPos"]) ?? position.column }
            let offset = target.text.location + min(column - 1, target.text.length)
            guard Range(NSRange(location: offset, length: 0), in: text) != nil else { return false }
            if let overtype = values["Overtype"]?.hostInt, overtype >= 0 { textView.overtype = overtype != 0 }
            luaInstallSelection(caret: offset, stream: stream, rectangle: luaRectangle,
                                visibleRanges: luaRectangle == nil ? [] : textView.selectedRanges)
            let top = positive(values["TopScreenLine"]).map { min(row, $0) }
            let left = positive(values["LeftPos"])
            if top != nil || left != nil {
                var origin = scroll.contentView.bounds.origin
                if let top, let layout = textView.layoutManager, layout.numberOfGlyphs > 0 {
                    let lineStart = coordinates.lines[top - 1].text.location
                    let glyph = layout.glyphIndexForCharacter(at: min(lineStart, max(0, source.length - 1)))
                    let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    origin.y = rect.minY + textView.textContainerOrigin.y
                }
                if let left { origin.x = CGFloat(min(EditorEditing.maximumRectangleCoordinate, left) - 1) * luaCellSize.width }
                scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(NSRect(origin: origin, size: scroll.contentSize)).origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            return true
        }
        func lineSelection(_ row: Int) -> (start: Int, end: Int) {
            let line = coordinates.lines[row - 1]
            if let rectangle = luaRectangle, (rectangle.firstLine...rectangle.lastLine).contains(row) {
                let value = source.substring(with: line.text)
                return (luaRealColumn(rectangle.firstColumn, in: value), luaRealColumn(rectangle.lastColumn, in: value) - 1)
            }
            guard let stream, NSIntersectionRange(line.full, stream).length > 0 else { return (0, 0) }
            let start = max(stream.location, line.text.location) - line.text.location + 1
            let end = NSMaxRange(stream) > NSMaxRange(line.text) ? -1 : NSMaxRange(stream) - line.text.location
            return (start, end)
        }
        func blockLastLine() -> Int {
            if let rectangle = luaRectangle { return min(rectangle.lastLine, coordinates.lines.count) }
            if let stream { return coordinates.position(max(stream.location, NSMaxRange(stream) - 1)).line }
            return 0
        }
        func selectBlock(type: Int, row: Int, column: Int, width: Int, height: Int) -> Bool {
            if type == 0 || column == 0 {
                luaInstallSelection(caret: caret)
                return true
            }
            let row = row == 0 ? position.line : row
            let limit = EditorEditing.maximumRectangleCoordinate
            guard type == 1 || type == 2, height > 0, row > 0, row <= coordinates.lines.count,
                  column > 0, column <= limit, (-limit...limit).contains(width) else { return false }
            let last = row + min(height, coordinates.lines.count - row + 1) - 1
            if type == 2 {
                let firstColumn = max(1, column + min(0, width))
                let lastColumn = firstColumn + abs(width)
                guard lastColumn <= limit, last - row < EditorEditing.maximumMatches else { return false }
                let block = EditorRectangle(firstLine: row, lastLine: last, firstColumn: firstColumn, lastColumn: lastColumn)
                let ranges = (row...last).compactMap { number -> NSValue? in
                    let line = coordinates.lines[number - 1].text
                    let value = source.substring(with: line)
                    let begin = min(line.length, luaRealColumn(firstColumn, in: value) - 1)
                    let end = min(line.length, luaRealColumn(lastColumn, in: value) - 1)
                    return end > begin ? NSValue(range: NSRange(location: line.location + begin, length: end - begin)) : nil
                }
                luaInstallSelection(caret: caret, rectangle: block, visibleRanges: ranges)
            } else {
                let first = coordinates.lines[row - 1]
                let final = coordinates.lines[last - 1]
                let start = first.text.location + min(column - 1, first.text.length)
                let endColumn = column - 1 + width
                let end = endColumn < 0 ? NSMaxRange(final.full) : final.text.location + min(endColumn, final.text.length)
                guard end >= start, Range(NSRange(location: start, length: end - start), in: text) != nil else { return false }
                luaInstallSelection(caret: caret, stream: end == start ? nil : NSRange(location: start, length: end - start))
            }
            return true
        }

        switch name {
        case "editor.GetFileName": return [.string(luaEditorFilename)]
        case "editor.GetInfo":
            return [.table(luaEditorInfo(coordinates, position: position, line: lineText, blockType: blockType, blockStart: blockStart))]
        case "editor.GetString":
            let mode = args.lua(2).hostInt ?? 0
            guard lineNumber > 0, coordinates.lines.indices.contains(lineNumber - 1), (0...4).contains(mode) else { return [.nilValue] }
            let line = coordinates.lines[lineNumber - 1]
            if mode == 1 || mode == 2 { _ = move(["CurLine": .hostInteger(lineNumber)]) }
            let value = source.substring(with: line.text), ending = source.substring(with: line.ending)
            if mode == 2 || mode == 3 { return [.string(value), .string(ending)] }
            let selected = lineSelection(lineNumber)
            if mode == 4 { return [.hostInteger(selected.start), .hostInteger(selected.end), .hostInteger(line.text.length)] }
            return [.table(["StringNumber": .hostInteger(requestedLine), "StringText": .string(value), "StringEOL": .string(ending),
                "StringLength": .hostInteger(line.text.length), "SelStart": .hostInteger(selected.start), "SelEnd": .hostInteger(selected.end)])]
        case "Editor.GetStr":
            let number = args.lua(0).hostInt ?? 0
            let row = number == 0 ? position.line : number
            return [.string(row > 0 && row <= coordinates.lines.count ? source.substring(with: coordinates.lines[row - 1].text) : "")]
        case "editor.SetString", "Editor.SetStr":
            let number = helper ? (args.lua(1).hostInt ?? 0) : lineNumber
            let row = number == 0 ? position.line : number
            let value = helper ? (args.lua(0).hostString ?? "") : args.lua(2).hostString
            guard row > 0, row <= coordinates.lines.count, let value, !value.contains(where: \.isNewline) else { return bool(false) }
            let line = coordinates.lines[row - 1]
            if !helper, let ending = args.lua(3).hostString {
                guard ["", "\n", "\r", "\r\n"].contains(ending) else { return bool(false) }
                return bool(replace(line.full, value + ending, preserveCaret: true))
            }
            return bool(replace(line.text, value, preserveCaret: true))
        case "editor.DeleteString": return bool(deleteLine(position.line))
        case "Editor.DelLine":
            let number = args.lua(0).hostInt ?? 0
            return bool(number >= 0 && deleteLine(number == 0 ? position.line : number))
        case "Editor.InsStr":
            let value = args.lua(0).hostString ?? ""
            let number = args.lua(1).hostInt ?? 0
            let row = number == 0 ? position.line : number
            guard row > 0, row <= coordinates.lines.count, !value.contains(where: \.isNewline) else { return bool(false) }
            let line = coordinates.lines[row - 1]
            let inserted = line.ending.length == 0 ? eol + value : value + source.substring(with: line.ending)
            return bool(replace(NSRange(location: NSMaxRange(line.full), length: 0), inserted, preserveCaret: true))
        case "editor.InsertText":
            guard let value = args.lua(1).hostString else { return bool(false) }
            return bool(replace(stream ?? NSRange(location: caret, length: 0), value))
        case "editor.InsertString":
            let indent = args.lua(1).hostBool && textView.autoIndentNewline
                ? String(lineText.prefix(while: { $0 == " " || $0 == "\t" })) : ""
            return bool(replace(NSRange(location: caret, length: 0), eol + indent))
        case "editor.DeleteChar":
            guard caret < source.length else { return bool(editable) }
            return bool(replace(source.rangeOfComposedCharacterSequence(at: caret), ""))
        case "editor.DeleteBlock":
            if let rectangle = luaRectangle {
                let edit = try EditorEditing.replaceRectangle(in: text, rectangle: rectangle, replacement: "", tabSize: tabSize)
                guard editable, withinBufferLimit(edit.text) else { return bool(false) }
                apply(edit, action: "LuaMacro")
                return bool(true)
            }
            guard let stream else { return bool(false) }
            return bool(replace(stream, ""))
        case "editor.SetPosition":
            if let values = args.lua(1).table { return bool(move(values)) }
            let keys = ["CurLine", "CurPos", "CurTabPos", "TopScreenLine", "LeftPos", "Overtype"]
            return bool(move(Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($0.element, args.lua($0.offset + 1)) })))
        case "Editor.Pos":
            let operation = args.lua(0).hostInt ?? 0, option = args.lua(1).hostInt ?? 0
            let keys = ["CurLine", "CurPos", "CurTabPos", "TopScreenLine", "LeftPos", "Overtype"]
            guard (1...keys.count).contains(option) else { return [.integer(-1)] }
            let key = keys[option - 1]
            if operation == 0 {
                return [luaEditorInfo(coordinates, position: position, line: lineText, blockType: blockType, blockStart: blockStart)[key] ?? .integer(-1)]
            }
            guard operation == 1 else { return [.integer(-1)] }
            var values = [key: args.lua(2)]
            if option == 5, let left = positive(args.lua(2)) {
                let oldLeft = max(1, Int(scroll.contentView.bounds.origin.x / luaCellSize.width) + 1)
                let shift = min(left, EditorEditing.maximumRectangleCoordinate) - oldLeft
                values["CurPos"] = .hostInteger(max(1, position.column + shift))
            }
            return bool(move(values))
        case "editor.GetSelection":
            guard blockType != 0 else { return [.nilValue] }
            let last = blockLastLine()
            return [.table(["BlockType": .hostInteger(blockType), "StartLine": .hostInteger(blockStart),
                "StartPos": .hostInteger(lineSelection(blockStart).start), "EndLine": .hostInteger(last), "EndPos": .hostInteger(lineSelection(last).end)])]
        case "editor.Select":
            let values = args.lua(1).hostTable
            let flags = ["BTYPE_NONE": 0, "BTYPE_STREAM": 1, "BTYPE_COLUMN": 2]
            let kind = values["BlockType"] ?? args.lua(1)
            guard let type = kind.hostInt ?? flags[kind.hostString ?? ""] else { return bool(false) }
            return bool(selectBlock(type: type, row: values["BlockStartLine"]?.hostInt ?? args.lua(2).hostInt ?? 0,
                column: values["BlockStartPos"]?.hostInt ?? args.lua(3).hostInt ?? 0,
                width: values["BlockWidth"]?.hostInt ?? args.lua(4).hostInt ?? -1,
                height: values["BlockHeight"]?.hostInt ?? args.lua(5).hostInt ?? -1))
        case "Editor.Sel":
            let action = args.lua(0).hostInt ?? 0, option = args.lua(1).hostInt ?? 0
            let last = blockLastLine()
            switch action {
            case 0:
                if option == 4 { return [.hostInteger(blockType)] }
                guard blockType != 0 else { return [.integer(0)] }
                let firstText = source.substring(with: coordinates.lines[blockStart - 1].text)
                let lastText = source.substring(with: coordinates.lines[last - 1].text)
                let lastEnd = lineSelection(last).end
                let values = [blockStart, luaVisualColumn(lineSelection(blockStart).start, in: firstText), last,
                              luaVisualColumn(lastEnd < 0 ? lastText.utf16.count + 1 : lastEnd + 1, in: lastText)]
                return [.hostInteger(values.indices.contains(option) ? values[option] : 0)]
            case 1:
                guard blockType != 0, option == 0 || option == 1 else { return bool(false) }
                let row = option == 0 ? blockStart : last
                let selected = lineSelection(row)
                let column = option == 0 ? selected.start : (selected.end < 0 ? coordinates.lines[row - 1].text.length + 1 : selected.end + 1)
                return bool(move(["CurLine": .hostInteger(row), "CurPos": .hostInteger(column)]))
            case 2, 3:
                if option == 0 { luaSelectionStart = caret; return bool(true) }
                guard option == 1, let anchor = luaSelectionStart else { return bool(false) }
                luaSelectionStart = nil
                if anchor == caret { luaInstallSelection(caret: caret); return bool(false) }
                let first = coordinates.position(min(anchor, caret)), last = coordinates.position(max(anchor, caret))
                if action == 2 {
                    luaInstallSelection(caret: caret, stream: NSRange(location: min(anchor, caret), length: abs(anchor - caret)))
                    return bool(true)
                }
                let firstColumn = luaVisualColumn(first.column, in: source.substring(with: coordinates.lines[first.line - 1].text))
                let lastColumn = luaVisualColumn(last.column, in: source.substring(with: coordinates.lines[last.line - 1].text))
                return bool(selectBlock(type: 2, row: first.line, column: firstColumn, width: lastColumn - firstColumn, height: last.line - first.line + 1))
            case 4: luaInstallSelection(caret: caret); return bool(true)
            default: return bool(false)
            }
        case "editor.UndoRedo", "Editor.Undo":
            let flags = ["EUR_BEGIN": 0, "EUR_END": 1, "EUR_UNDO": 2, "EUR_REDO": 3]
            let value = args.lua(helper ? 0 : 1)
            guard let action = value.hostInt ?? flags[value.hostString ?? ""] ?? (helper && value == .nilValue ? 0 : nil) else { return bool(false) }
            return bool(luaUndoRedo(action))
        case "editor.AddColor", "editor.GetColor", "editor.DelColor":
            guard lineNumber > 0, lineNumber <= coordinates.lines.count else {
                return name == "editor.GetColor" ? [.nilValue] : bool(false)
            }
            return luaColorCall(name, args, line: lineNumber, range: coordinates.lines[lineNumber - 1].text)
        case "editor.SetTitle", "Editor.SetTitle":
            let title = args.lua(helper ? 0 : 1).hostString
            luaTitle = title.flatMap { $0.isEmpty ? nil : $0 }
            updateState()
            return bool(true)
        case "editor.GetTitle": return [.string(luaTitle ?? "")]
        case "Editor.Set": return [luaEditorSetting(args)]
        case "editor.SaveFile": return bool(luaSaveFile(args))
        case "editor.Redraw": textView.needsDisplay = true; return bool(true)
        case "editor.Quit": window?.performClose(nil); return bool(closed)
        case "editor.RealToTab", "editor.TabToReal":
            guard lineNumber > 0, lineNumber <= coordinates.lines.count, let requested = positive(args.lua(2)) else { return [.nilValue] }
            let line = source.substring(with: coordinates.lines[lineNumber - 1].text)
            return [.hostInteger(name == "editor.RealToTab" ? luaVisualColumn(requested, in: line) : luaRealColumn(requested, in: line))]
        default: throw ExtensionAPIError("API пока не перенесён: \(name)")
        }
    }

    private func positive(_ value: FarLuaValue?) -> Int? {
        value?.hostInt.flatMap { $0 > 0 ? $0 : nil }
    }
}

private struct LuaEditorColor {
    let line: Int
    let start: Int
    let end: Int
    let range: NSRange
    let flags: Int
    let priority: Int
    let owner: String
    let color: [String: FarLuaValue]

    var apiValue: FarLuaValue {
        .table(["StartPos": .hostInteger(start), "EndPos": .hostInteger(end), "Flags": .hostInteger(flags),
                "Priority": .hostInteger(priority), "Color": .table(color), "Owner": .string(owner)])
    }
}

extension TextFileWindow {
    func luaRequestRedraw() {
        guard !closed, luaReadSent, !luaRedrawScheduled, FarLuaWorkspace.shared.hasEventHandlers("EditorEvent") else { return }
        luaRedrawScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.luaRedrawScheduled = false
            guard !self.closed else { return }
            let oldCount = self.luaColors.count
            self.luaColors.removeAll { $0.flags & 4 != 0 }
            if oldCount != self.luaColors.count { self.luaPaintColorLayers() }
            self.luaEditorEvent(2, .integer(1))
        }
    }

    private func luaColorCall(_ name: String, _ args: [FarLuaValue], line: Int, range: NSRange) -> [FarLuaValue] {
        switch name {
        case "editor.GetColor":
            let index = args.lua(2).hostInt ?? -1
            let items = luaColors.filter { $0.line == line }
            return items.indices.contains(index) ? [items[index].apiValue] : [.nilValue]
        case "editor.DelColor":
            let start = args.lua(2).hostInt ?? 0, owner = (args.lua(3).hostString ?? "").lowercased()
            luaColors.removeAll { $0.line == line && $0.owner == owner && (start == 0 || $0.start == start) }
            luaScheduleColorPaint()
            return [.bool(true)]
        default:
            guard let start = positive(args.lua(2)), let end = positive(args.lua(3)),
                  end >= start, end <= range.length, luaColors.count < 16_384 else { return [.bool(false)] }
            let selected = NSRange(location: range.location + start - 1, length: end - start + 1)
            guard Range(selected, in: textView.string) != nil else { return [.bool(false)] }
            let flagsValue = args.lua(4)
            let flags = flagsValue.hostInt ?? ["ECF_NONE": 0, "ECF_TABMARKFIRST": 1,
                "ECF_TABMARKCURRENT": 2, "ECF_AUTODELETE": 4][flagsValue.hostString ?? ""] ?? 0
            let value = args.lua(5)
            let color: [String: FarLuaValue]
            if let legacy = value.hostInt, (0...255).contains(legacy) {
                color = ["Flags": .integer(3), "ForegroundColor": .hostInteger(legacy & 0xf),
                         "BackgroundColor": .hostInteger((legacy >> 4) & 0xf)]
            } else if let table = value.table, table["ForegroundColor"]?.hostInt != nil || table["BackgroundColor"]?.hostInt != nil {
                color = table
            } else {
                return [.bool(false)]
            }
            let priority = args.lua(6).hostInt ?? 0x80000000
            guard priority >= 0, priority <= Int(UInt32.max) else { return [.bool(false)] }
            let owner = (args.lua(7).hostString ?? "").lowercased()
            luaColors.append(LuaEditorColor(line: line, start: start, end: end, range: selected, flags: flags,
                priority: priority, owner: owner, color: color))
            luaScheduleColorPaint()
            return [.bool(true)]
        }
    }

    private func luaScheduleColorPaint() {
        guard !luaColorPaintScheduled else { return }
        luaColorPaintScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            guard let self else { return }
            self.luaColorPaintScheduled = false
            if !self.closed { self.luaPaintColorLayers() }
        }
    }

    private func luaPaintColorLayers() {
        guard let layout = textView.layoutManager else { return }
        let full = NSRange(location: 0, length: textView.string.utf16.count)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        for span in syntaxSpans where NSMaxRange(span.range) <= full.length {
            let color: NSColor
            switch span.kind {
            case .keyword: color = .systemPink
            case .string: color = .systemGreen
            case .number: color = .systemOrange
            case .comment: color = .systemGray
            case .literal: color = .systemTeal
            }
            layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: span.range)
        }
        for item in luaColors.sorted(by: { $0.priority < $1.priority }) where NSMaxRange(item.range) <= full.length {
            let flags = item.color["Flags"]?.hostInt ?? 0
            if let color = Self.luaNSColor(item.color["ForegroundColor"]?.hostInt, indexed: flags & 1 != 0) {
                layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: item.range)
            }
            if let color = Self.luaNSColor(item.color["BackgroundColor"]?.hostInt, indexed: flags & 2 != 0) {
                layout.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: item.range)
            }
        }
        textView.needsDisplay = true
    }

    private static func luaNSColor(_ raw: Int?, indexed: Bool) -> NSColor? {
        guard let raw else { return nil }
        let color = UInt32(truncatingIfNeeded: raw)
        if indexed {
            let palette: [UInt32] = [
                0x000000, 0x800000, 0x008000, 0x808000, 0x000080, 0x800080, 0x008080, 0xc0c0c0,
                0x808080, 0xff0000, 0x00ff00, 0xffff00, 0x0000ff, 0xff00ff, 0x00ffff, 0xffffff
            ]
            return luaNSColor(Int(palette[Int(color & 0xf)] | 0xff000000), indexed: false)
        }
        let alpha = CGFloat(color >> 24) / 255
        guard alpha > 0 else { return nil }
        return NSColor(srgbRed: CGFloat(color & 255) / 255, green: CGFloat((color >> 8) & 255) / 255,
                       blue: CGFloat((color >> 16) & 255) / 255, alpha: alpha)
    }
}

extension TextFileWindow {
    static func runLuaEditorUISmoke() throws -> [String] {
        guard AppRuntime.isSmoke, let root = AppRuntime.smokeStateDirectory else {
            throw ExtensionAPIError("Lua editor smoke requires isolated state.")
        }
        let directory = root.appendingPathComponent("lua-editor-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.txt")
        let text = "\talpha\r\n\tbeta\r\n🙂tail"
        try Data(text.utf8).write(to: original)
        let editor = try TextFileWindow(url: original, useRememberedEncoding: false)
        editor.showWindow(nil)
        defer { editor.closeArchiveWorkingCopyWithoutSaving() }

        func call(_ name: String, _ values: FarLuaValue...) throws -> [FarLuaValue] {
            try editor.luaEditorCall(name, values)
        }
        func require(_ value: Bool, _ detail: String) throws {
            guard value else { throw ExtensionAPIError(detail) }
        }
        let set = try call("editor.SetPosition", .nilValue, .table(["CurLine": .integer(2), "CurTabPos": .integer(6)]))
        try require(set == [.bool(true)], "Lua editor tab cursor could not be set.")
        let info = try call("editor.GetInfo").first?.hostTable ?? [:]
        try require(info["CurLine"] == .integer(2) && info["CurPos"] == .integer(3) &&
            info["CurTabPos"] == .integer(6) && info["CodePage"] == .integer(65001), "Lua editor returned wrong tab, line or code-page metadata.")
        let line = try call("editor.GetString", .nilValue, .integer(1), .integer(3))
        try require(line == [.string("\talpha"), .string("\r\n")], "Lua editor must preserve the line's CRLF.")
        let beforeMove = try call("Editor.Pos", .integer(0), .integer(1))
        try require(beforeMove == [.integer(2)], "GetString mode 3 moved the editor caret.")
        let moved = try call("editor.GetString", .nilValue, .integer(1), .integer(2))
        let afterMove = try call("Editor.Pos", .integer(0), .integer(1))
        try require(moved == line && afterMove == [.integer(1)], "GetString mode 2 must move the editor caret.")
        let selected = try call("editor.Select", .nilValue, .string("BTYPE_COLUMN"), .integer(1), .integer(5), .integer(1), .integer(2))
        let details = try call("editor.GetSelection").first?.hostTable ?? [:]
        let markers = try call("editor.GetString", .nilValue, .integer(1), .integer(4))
        try require(selected == [.bool(true)] && details["BlockType"] == .integer(2) && details["EndLine"] == .integer(2) &&
            markers == [.integer(2), .integer(2), .integer(6)] && editor.luaEditorProperties.hostTable["SelValue"] == .string("a\nb"),
            "Lua rectangular selection metadata did not agree with the selected text.")

        guard let undo = editor.textView.undoManager else { throw ExtensionAPIError("Lua editor has no undo manager.") }
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        let outer = undo.groupingLevel
        let begin = try call("editor.UndoRedo", .nilValue, .string("EUR_BEGIN"))
        let deleted = try call("editor.DeleteBlock")
        try require(begin == [.bool(true)] && deleted == [.bool(true)] && editor.textView.string == "\tlpha\r\n\teta\r\n🙂tail",
            "Lua editor did not delete the rectangular block through the normal editing path.")
        editor.luaFinishUndoGroups()
        try require(undo.groupingLevel == outer, "Finishing a Lua undo group closed its caller's group.")
        undo.endUndoGrouping()
        let undone = try call("Editor.Undo", .integer(2))
        try require(undone == [.integer(1)] && editor.textView.string == text, "Lua grouped undo did not restore the rectangular block.")

        let owner: FarLuaValue = .string("507cfa2a-3ba3-4f2b-8a80-318f5a831235")
        let color: FarLuaValue = .table(["Flags": .integer(0), "ForegroundColor": .integer(0xff0000ff), "BackgroundColor": .integer(0xffff0000)])
        let added = try call("editor.AddColor", .nilValue, .integer(1), .integer(2), .integer(4), .integer(4), color, .integer(100), owner)
        let item = try call("editor.GetColor", .nilValue, .integer(1), .integer(0)).first?.hostTable
        editor.luaPaintColorLayers()
        let painted = editor.textView.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 1, effectiveRange: nil) as? NSColor
        try require(added == [.bool(true)] && item?["Priority"] == .integer(100) && item?["Owner"] == owner && painted != nil,
            "Lua editor color must be stored and applied as a temporary display attribute.")
        _ = try call("editor.DelColor", .nilValue, .integer(1), .integer(0), owner)
        let remaining = try call("editor.GetColor", .nilValue, .integer(1), .integer(0))
        try require(remaining == [.nilValue], "Lua editor color owner could not delete the item.")

        let saved = directory.appendingPathComponent("changed name.txt")
        let savedOK = try call("editor.SaveFile", .nilValue, .string(saved.lastPathComponent), .string("\n"), .integer(1200))
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let bytes = try Data(contentsOf: saved)
        let oldBytes = try Data(contentsOf: original)
        let current = try call("editor.GetFileName")
        try require(savedOK == [.bool(true)] && String(data: bytes, encoding: .utf16LittleEndian) == normalized &&
            oldBytes == Data(text.utf8) && current == [.string(saved.path)], "Lua SaveFile did not preserve the original and switch to the saved path and format.")
        let external = Data("changed outside editor".utf8)
        try external.write(to: saved, options: .atomic)
        let conflicted = try call("editor.SaveFile")
        let existing = try Data(contentsOf: saved)
        try require(conflicted == [.bool(false)] && existing == external, "Lua SaveFile overwrote a concurrent change.")

        return ["Lua editor UTF-16/tab positions and GetString mode semantics",
            "Lua rectangular selection, deletion and owned undo groups", "Lua editor color ownership and AppKit display layer",
            "Lua SaveFile path/EOL/codepage conversion and conflict guard"]
    }
}

extension TextFileWindow {
    static func runLuaMoonUISmoke() async throws -> [String] {
        guard AppRuntime.isSmoke, let root = AppRuntime.smokeStateDirectory, let app = NSApp.delegate as? AppDelegate else {
            throw ExtensionAPIError("MoonScript editor smoke requires isolated state and the live AppKit host.")
        }
        let url = root.appendingPathComponent("lua-color-word-" + UUID().uuidString + ".txt")
        try Data("alpha beta alpha\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        guard app.luaOpenFile(url, editable: true), let editor = app.luaEditor(for: url), let window = editor.window else {
            throw ExtensionAPIError("MoonScript editor smoke could not open its fixture.")
        }
        defer { editor.closeArchiveWorkingCopyWithoutSaving() }
        try await app.focusSmokeWindow(window)

        let host = FarLuaWorkspace.shared, runtime = try FarLuaRuntime()
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: sourceRoot.appendingPathComponent("Tests/FarCoreTests/Fixtures/FarLua/Editor.ColorWord.moon"), encoding: .utf8)
        try runtime.load(source: source, name: "Editor.ColorWord.moon", language: .moonScript, snapshot: host.snapshot())
        guard let macro = try runtime.matchingMacros(key: "F5", snapshot: host.snapshot()).first else {
            throw ExtensionAPIError("The original Color Word macro did not match F5 in the live editor.")
        }
        let arguments: [FarLuaValue] = [editor.luaEditorID, .integer(2), .integer(1)]
        guard let redraw = try runtime.matchingEvents(group: "EditorEvent", snapshot: host.snapshot(), arguments: arguments).first else {
            throw ExtensionAPIError("The original Color Word script did not register its editor event.")
        }

        func toggle() async throws {
            _ = try await host.drive(runtime.start(macro, snapshot: host.snapshot(), key: "F5"), runtime: runtime)
            editor.luaColors.removeAll { $0.flags & 4 != 0 }
            _ = try await host.drive(runtime.start(redraw, snapshot: host.snapshot(), arguments: arguments), runtime: runtime)
            editor.luaPaintColorLayers()
        }
        func hasBackground(_ offset: Int) -> Bool {
            editor.textView.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: offset, effectiveRange: nil) != nil
        }
        try await toggle()
        guard editor.luaColors.map(\.start) == [1, 12], hasBackground(0), hasBackground(11), !hasBackground(6) else {
            throw ExtensionAPIError("The original Color Word script failed to paint precisely the two matching words.")
        }
        try await toggle()
        guard editor.luaColors.isEmpty, !hasBackground(0), !hasBackground(11) else {
            throw ExtensionAPIError("The original Color Word script did not clear its highlighting on the second F5.")
        }
        return ["Unmodified FAR Color Word MoonScript paints matching words in AppKit and toggles off on F5"]
    }
}

extension TextFileWindow {
    func showAutoWrapSettings() { AutoWrapWorkspace.show() }

    private func trackAutoWrap() -> (() -> Void)? {
        guard editable, !closed, let settings = AutoWrapWorkspace.settings(for: displayName) else { return nil }
        let coordinates = luaCoordinates(), caret = textView.selectedRange().location
        let line = coordinates.position(caret).line
        let previous = EditorAutoWrap.Baseline(line: line, length: coordinates.lines[line - 1].text.length)
        let originalRevision = generation
        return { [weak self] in
            guard let self, !self.closed, self.generation != originalRevision else { return }
            do {
                if let result = try EditorAutoWrap.wrapAfterInput(in: self.textView.string, caret: self.textView.selectedRange().location,
                    previous: previous, rightMargin: settings.rightMargin, tabSize: self.tabSize, autoIndent: self.textView.autoIndentNewline,
                    fallbackEOL: self.editorPreferredEOL, requireSameLine: !settings.includeMasks.isEmpty),
                   self.withinBufferLimit(result.text) {
                    self.apply(result, action: "Автоперенос")
                }
            } catch {
                self.operationStatus = error.localizedDescription
                self.updateState()
            }
        }
    }

    private var editorPreferredEOL: String {
        switch format.lineEnding {
        case .lf: return "\n"
        case .cr: return "\r"
        case .crlf: return "\r\n"
        case .preserve:
            let text = textView.string as NSString
            return luaCoordinates().lines.first(where: { $0.ending.length > 0 }).map { text.substring(with: $0.ending) } ?? "\n"
        }
    }

    func startDrawLine() {
        guard editable, !closed, !drawLineActive, let undo = textView.undoManager else { return }
        textView.breakUndoCoalescing()
        undo.beginUndoGrouping()
        drawLineUndoLevel = undo.groupingLevel
        drawLineMode = EditorDrawLine()
        window?.makeFirstResponder(textView)
        updateState()
    }

    private func stopDrawLine() {
        guard drawLineActive else { return }
        drawLineMode = nil
        textView.breakUndoCoalescing()
        if let undo = textView.undoManager, let level = drawLineUndoLevel, undo.groupingLevel == level {
            undo.setActionName("Рисование линий")
            undo.endUndoGrouping()
        }
        drawLineUndoLevel = nil
        updateState()
    }

    private func drawLineKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        switch event.keyCode {
        case 53, 109:
            if flags.isEmpty { stopDrawLine() }
            return true
        case 122:
            drawLineMode?.resetDirection()
            let alert = NSAlert()
            alert.messageText = "Рисование линий"
            alert.informativeText = "Shift+стрелки — рисовать. Ctrl+Shift+стрелки — шаг на ширину табуляции. F2 — сменить одинарную или двойную линию. F10 и Esc — выйти."
            alert.runModal()
            return true
        case 120:
            if flags.isEmpty { drawLineMode?.toggleStyle(); updateState() }
            return true
        case 99, 118, 96, 97, 98, 100, 101, 103, 111:
            drawLineMode?.resetDirection()
            return true
        default:
            break
        }
        let arrows: [UInt16: EditorDrawLine.Direction] = [123: .left, 124: .right, 125: .down, 126: .up,
                                                         86: .left, 88: .right, 84: .down, 91: .up]
        guard flags.contains(.shift), !flags.contains(.command), let direction = arrows[event.keyCode] else {
            drawLineMode?.resetDirection()
            return false
        }
        guard var mode = drawLineMode else { return false }
        do {
            let edit = try mode.draw(in: textView.string, caret: textView.selectedRange().location,
                toward: direction, accelerated: flags.contains(.control), tabSize: tabSize, fallbackEOL: editorPreferredEOL)
            guard withinBufferLimit(edit.text) else { throw EditorError.tooLarge }
            drawLineMode = mode
            apply(edit, action: "Рисование линий")
        } catch {
            operationStatus = error.localizedDescription
            updateState()
            NSSound.beep()
        }
        return true
    }
}

extension TextFileWindow {
    static func runStockEditorPluginUISmoke() throws -> [String] {
        guard AppRuntime.isSmoke, let root = AppRuntime.smokeStateDirectory else {
            throw ExtensionAPIError("Stock editor plugin smoke requires isolated state.")
        }
        var settings = EditorAutoWrapSettings()
        settings.enabled = true; settings.rightMargin = 8; settings.includeMasks = "*.txt"; settings.excludeMasks = "excluded*"
        try AutoWrapWorkspace.withSmokeSettings(settings) {
            for (name, expected) in [("wrap.txt", "one two \nthr"), ("excluded.txt", "one two thr")] {
                let url = root.appendingPathComponent(name)
                let editor = TextFileWindow(newIn: root, named: url)
                editor.showWindow(nil)
                defer { editor.closeArchiveWorkingCopyWithoutSaving() }
                editor.textView.string = "one two th"
                editor.select(NSRange(location: 10, length: 0))
                editor.textView.insertText("r", replacementRange: editor.textView.selectedRange())
                guard editor.textView.string == expected else {
                    throw ExtensionAPIError("AutoWrap did not follow the filename mask and right margin for \(name).")
                }
            }
        }
        let editor = TextFileWindow(newIn: root)
        editor.showWindow(nil)
        defer { editor.closeArchiveWorkingCopyWithoutSaving() }
        guard let undo = editor.textView.undoManager else { throw ExtensionAPIError("DrawLine has no undo manager.") }
        undo.groupsByEvent = false
        editor.startDrawLine()
        func press(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> Bool {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: editor.window?.windowNumber ?? 0, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) else { return false }
            return editor.drawLineKey(event)
        }
        guard editor.drawLineActive, press(124, .shift), press(124, .shift), press(125, .shift),
              editor.textView.string == "─┐\n", press(120), editor.window?.title.contains("╬") == true,
              press(109), !editor.drawLineActive, undo.canUndo else {
            throw ExtensionAPIError("DrawLine did not draw a turn and restore the ordinary editor after F10.")
        }
        undo.undo()
        guard editor.textView.string.isEmpty else { throw ExtensionAPIError("DrawLine must undo the entire session as one action.") }
        return ["AutoWrap changes real editor input and respects separate exclusion masks", "DrawLine arrows, F2 and F10 drive one undoable editing session"]
    }
}
