import AppKit
import FarCore

/// Independent editor buffers. Persistent bytes, recovery and text operations
/// live in FarCore; this controller owns only the AppKit document experience.
@MainActor
final class TextFileWindow: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSMenuItemValidation {
    static let helpText = """
    Редактор: F2 / ⌘S — сохранить; Shift F2 / ⇧⌘S — сохранить как.
    F7 / ⌘F — поиск; Shift F7 — далее; Alt F7 — назад; Ctrl F7 / ⌘⌥F — замена.
    Alt F8 / ⌘L — строка и столбец; Ctrl F3 — номера строк.
    Tab / Shift Tab или Alt I / Alt U — отступ / убрать отступ.
    Прямоугольный блок задаётся кнопкой «Блок» (строки включительно, последний столбец не включён).
    F6 — просмотр; F4 / F10 / Esc — закрыть; Shift F10 — сохранить и закрыть.
    ⌘Z / ⇧⌘Z — отменить / повторить. Shift F4 / ⌘N — новый файл.
    Предел текста — 8 МиБ; подсветка отключается после 256 КиБ.
    Новый файл: UTF-8 без BOM; ввод Enter — LF. Исходные и вставленные окончания строк сохраняются;
    преобразование всех окончаний выполняется только при явном выборе LF / CRLF в «Сохранить как».
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
    var hasUnsavedChanges: Bool { isDirty }
    var workingFileURL: URL? { sourceURL }
    func saveForArchiveCommit() -> Bool { save() }
    func closeArchiveWorkingCopyWithoutSaving() { pendingDiscard = true; window?.close() }

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
        let date: Date
    }
    private static let historyDefaultsKey = "editor.history.v1"
    private static func historyRecords() -> [HistoryRecord] {
        guard let data = UserDefaults.standard.data(forKey: historyDefaultsKey) else { return [] }
        return (try? JSONDecoder().decode([HistoryRecord].self, from: data)) ?? []
    }
    private static func historyRecord(_ url: URL) -> HistoryRecord? {
        historyRecords().first { $0.path == url.standardizedFileURL.path }
    }
    private func persistHistory() {
        guard retainedArchiveWorkspace == nil, retainedRemoteWorkspace == nil, let sourceURL, let snapshot else { return }
        let record = HistoryRecord(path: sourceURL.standardizedFileURL.path, identity: snapshot.identity,
                                   encoding: snapshot.format.encoding, position: textView.selectedRange().location, date: Date())
        var records = Self.historyRecords().filter { $0.path != record.path }; records.append(record)
        records.sort { $0.date > $1.date }
        if let data = try? JSONEncoder().encode(Array(records.prefix(100))) { UserDefaults.standard.set(data, forKey: Self.historyDefaultsKey) }
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
    private var rectangle: EditorRectangle?
    private var tabSize = 4
    private var useSpaces = true
    private static let foreground = NSColor(calibratedRed: 0.88, green: 0.92, blue: 1, alpha: 1)
    private static let background = NSColor(calibratedRed: 0.035, green: 0.065, blue: 0.14, alpha: 1)

    init(url: URL, editable: Bool = true, initialByteOffset: Int64? = nil,
         encoding: ViewerEncoding = .automatic,
         onView: ((URL, Int64, ViewerEncoding) -> Bool)? = nil) throws {
        let history = Self.historyRecord(url)
        let loaded: EditorSnapshot
        if encoding == .automatic, let rememberedEncoding = history?.encoding {
            do { loaded = try EditorDocument.load(url: url, encoding: rememberedEncoding) }
            catch { loaded = try EditorDocument.load(url: url, encoding: .automatic) }
        } else { loaded = try EditorDocument.load(url: url, encoding: encoding) }
        sourceURL = loaded.originalURL; initialDirectory = loaded.originalURL.deletingLastPathComponent()
        snapshot = loaded; format = loaded.format; savedFormat = loaded.format; savedText = loaded.text
        recoveryID = UUID(); self.editable = editable; self.onView = onView
        super.init(window: Self.makeWindow())
        configureContent(loaded.text)
        let position = initialByteOffset.map { EditorDocument.utf16Offset(forByteOffset: $0, in: loaded) }
            ?? (history?.identity == loaded.identity ? history?.position ?? 0 : 0)
        select(NSRange(location: min(position, loaded.text.utf16.count), length: 0))
        updateState(); scheduleHighlight()
    }

    init(newIn directory: URL, onView: ((URL, Int64, ViewerEncoding) -> Bool)? = nil) {
        sourceURL = nil; initialDirectory = directory; snapshot = nil
        format = EditorFormat(); savedFormat = format; savedText = ""; recoveryID = UUID()
        editable = true; self.onView = onView
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
    static func pendingRecoveries() throws -> [EditorRecoveryRecord] { try EditorRecoveryStore().loadAll() }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 800, height: 420)
        window.appearance = NSAppearance(named: .darkAqua); window.backgroundColor = background; window.center()
        return window
    }


    override func showWindow(_ sender: Any?) {
        retainedWhileOpen = self; window?.delegate = self
        super.showWindow(sender); window?.makeFirstResponder(textView)
        textView.scrollRangeToVisible(textView.selectedRange())
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window, self.window?.attachedSheet == nil,
                      self.window?.isKeyWindow == true else { return event }
                return self.handleKey(event) ? nil : event
            }
        }
        if activationObserver == nil {
            activationObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.checkExternalChange() }
            }
        }
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
        tabsPopup.addItems(withTitles: ["Tab 2", "Tab 4", "Tab 8"]); tabsPopup.selectItem(at: 1)
        tabsPopup.target = self; tabsPopup.action = #selector(tabsChanged(_:))
        spacesCheck.state = .on; spacesCheck.target = self; spacesCheck.action = #selector(tabsChanged(_:))
        let toolbar = NSStackView(views: [findButton, replaceButton, gotoButton, blockButton, lineButton, NSView(), tabsPopup, spacesCheck])
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
        textView.string = contents; textView.delegate = self
        textView.indentSelection = { [weak self] outdent in self?.indent(outdent: outdent) }
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
        let viewButton = button("F6 Просмотр", #selector(switchToViewer(_:))); viewButton.isHidden = !editable || onView == nil
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
        generation += 1; searchGeneration += 1; searchPending = false; lastFoundRange = nil; operationStatus = ""; pendingDiscard = false
        updateState(); ruler?.needsDisplay = true; scheduleHighlight(); scheduleRecovery()
    }
    func textViewDidChangeSelection(_ notification: Notification) { updateState(); ruler?.needsDisplay = true }
    private func withinBufferLimit(_ text: String) -> Bool {
        // Count encoded width without transcoding the whole buffer on every key.
        // Legacy drafts may contain temporarily unrepresentable characters;
        // recovery keeps them, while the storage codec refuses a lossy save.
        let bom = format.bom ? (format.encoding == .utf8 ? 3 : 2) : 0
        let bytes: Int
        switch format.encoding {
        case .utf8, .automatic: bytes = text.utf8.count
        case .utf16LE, .utf16BE: bytes = text.utf16.count * 2
        case .windows1251, .windows1252, .latin1: bytes = text.unicodeScalars.count
        }
        return bytes + bom <= EditorDocument.maximumSize
    }
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard let replacementString else { return true }
        let updated = (textView.string as NSString).replacingCharacters(in: affectedCharRange, with: replacementString)
        guard withinBufferLimit(updated) else { operationStatus = "Изменение отклонено: предел текста 8 МиБ"; updateState(); NSSound.beep(); return false }
        return true
    }
    @objc private func scrolled(_ notification: Notification) { ruler?.needsDisplay = true }

    private func updateState() {
        let name = displayName
        nameLabel.stringValue = name + (editable ? "" : " · Только чтение")
        pathLabel.stringValue = (displayName == workingCopyDisplayName ? workingCopyDisplayPath : nil) ?? sourceURL?.path ?? initialDirectory.path + "/ — новый файл"
        window?.title = name + (editable ? " — Редактор" : " — Просмотр")
        window?.representedURL = sourceURL; window?.isDocumentEdited = isDirty
        saveButton.isEnabled = editable && (isDirty || sourceURL == nil)
        let offset = textView.selectedRange().location
        let positionText: String
        if cachedPositionRevision == generation, cachedPositionOffset == offset { positionText = "\(cachedPosition.line):\(cachedPosition.column)" }
        else { positionText = "…"; schedulePosition(offset: offset) }
        let syntax = textView.string.utf8.count > 256 * 1024 ? " · Подсветка выключена: >256 КиБ" : ""
        let extra = recoveryWarning.isEmpty ? operationStatus : recoveryWarning
        statusLabel.stringValue = "\(positionText) · \(format.encoding.title)\(format.bom ? " BOM" : "") · \(format.lineEnding.title)\(isDirty ? " · Изменён" : "")\(syntax)\(extra.isEmpty ? "" : " · " + extra)"
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
        case #selector(saveDocument(_:)): return editable && (isDirty || sourceURL == nil)
        case #selector(saveAsDocument(_:)): return editable
        default: return true
        }
    }
    @objc func saveDocument(_ sender: Any?) { _ = save() }
    @discardableResult private func save() -> Bool {
        guard editable else { return true }
        guard let sourceURL, let snapshot else { return saveAs() }
        guard isDirty else { return true }
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
        let id = recoveryID
        recoveryQueue.async { [weak self] in
            do {
                try EditorRecoveryStore().remove(id: id)
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
        let work = DispatchWorkItem { [weak self] in
            do {
                try EditorRecoveryStore().save(record)
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
                textView.string = loaded.text; textView.undoManager?.removeAllActions()
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
    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmClose() }
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
        guard let onView else { return }
        if sourceURL == nil, !save() { return }
        guard confirmClose(), let sourceURL else { return }
        let displayed = isDirty ? savedText : textView.string
        do {
            let offset = try EditorDocument.byteOffset(forUTF16Offset: min(textView.selectedRange().location, displayed.utf16.count), text: displayed, format: savedFormat)
            if onView(sourceURL, offset, savedFormat.encoding) { window?.close() }
        } catch { showError("Не удалось перейти к просмотру", error) }
    }
    /// Called after every app termination guard has accepted closing.
    func finalizeClose() {
        persistHistory()
        recoveryWork?.cancel()
        if pendingDiscard || !isDirty {
            do { try recoveryQueue.sync { try EditorRecoveryStore().remove(id: recoveryID) } }
            catch { showError("Черновик восстановления не удалён", error) }
        } else {
            // Finish a successful save's queued removal before Cmd-Q exits.
            recoveryQueue.sync {}
        }
    }
    func moveToByteOffset(_ offset: Int64) {
        guard let snapshot else { return }
        select(NSRange(location: EditorDocument.utf16Offset(forByteOffset: offset, in: snapshot), length: 0))
    }
    func windowWillClose(_ notification: Notification) {
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
        let regex = NSButton(checkboxWithTitle: "Регулярное выражение (в пределах строки)", target: nil, action: nil)
        regex.state = lastQuery?.regex == true ? .on : .off
        let caseSensitive = NSButton(checkboxWithTitle: "Учитывать регистр", target: nil, action: nil)
        caseSensitive.state = lastQuery?.caseSensitive == true ? .on : .off
        let words = NSButton(checkboxWithTitle: "Целые слова", target: nil, action: nil)
        words.state = lastQuery?.wholeWords == true ? .on : .off
        let direction = NSPopUpButton(); direction.addItems(withTitles: ["Вперёд", "Назад"])
        var views: [NSView] = [row("Найти", pattern)]
        if replacing { views.append(row("Заменить", replacement)) }
        views += [regex, caseSensitive, words, row("Направление", direction)]
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 9
        stack.frame = NSRect(x: 0, y: 0, width: 480, height: replacing ? 215 : 175); alert.accessoryView = stack
        alert.addButton(withTitle: replacing ? "Заменить" : "Найти")
        if replacing { alert.addButton(withTitle: "Заменить всё") }
        alert.addButton(withTitle: "Отмена")
        alert.window.initialFirstResponder = pattern
        let answer = alert.runModal()
        guard answer == .alertFirstButtonReturn || (replacing && answer == .alertSecondButtonReturn) else { return }
        let query = EditorSearchQuery(pattern: pattern.stringValue, regex: regex.state == .on,
                                      caseSensitive: caseSensitive.state == .on, wholeWords: words.state == .on)
        lastQuery = query; lastReplacement = replacement.stringValue
        if replacing {
            performReplacement(query: query, replacement: replacement.stringValue, all: answer == .alertSecondButtonReturn,
                               direction: direction.indexOfSelectedItem == 1 ? .backward : .forward)
        } else { find(query, direction: direction.indexOfSelectedItem == 1 ? .backward : .forward) }
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

    private func performReplacement(query: EditorSearchQuery, replacement: String, all: Bool, direction: ViewerSearchDirection) {
        let text = textView.string, selection = textView.selectedRange(), revision = generation
        searchGeneration += 1; let request = searchGeneration
        searchPending = true; operationStatus = "Замена… (Esc — отменить)"; updateState()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<EditorEdit?, Error> = Result {
                if all { return try EditorEditing.replaceAll(in: text, query: query, replacement: replacement) }
                // Include the current selection, so Find followed by Replace edits it.
                let start = direction == .forward ? selection.location : NSMaxRange(selection)
                guard let range = try EditorEditing.find(in: text, query: query, from: start, direction: direction) else { return nil }
                let updated = try EditorEditing.replace(in: text, range: range, query: query, replacement: replacement)
                let addedLength = updated.utf16.count - text.utf16.count + range.length
                return EditorEdit(text: updated, selection: NSRange(location: range.location, length: addedLength), count: 1)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, self.generation == revision, self.searchGeneration == request else { return }
                self.searchPending = false
                switch result {
                case .success(let edit):
                    if let edit { self.apply(edit, action: all ? "Заменить всё" : "Заменить"); self.operationStatus = "Замен: \(edit.count)" }
                    else { self.operationStatus = "Совпадений нет"; NSSound.beep() }
                case .failure(let error): self.showError("Замена не выполнена", error); self.operationStatus = "Замена остановлена"
                }
                self.updateState(); self.window?.makeFirstResponder(self.textView)
            }
        }
    }

    private func apply(_ edit: EditorEdit, action: String) {
        guard editable else { return }
        replaceBuffer(edit.text, selection: edit.selection, action: action)
    }
    private func replaceBuffer(_ text: String, selection: NSRange, action: String) {
        guard text != textView.string else { select(selection); return }
        // Keep temporarily unrepresentable characters editable: Save As can
        // select Unicode, and recovery still preserves the complete draft.
        guard withinBufferLimit(text) else { showError("Изменение не выполнено", EditorError.tooLarge); return }
        let manager = textView.undoManager
        textView.breakUndoCoalescing(); manager?.beginUndoGrouping()
        let full = NSRange(location: 0, length: textView.string.utf16.count)
        if textView.shouldChangeText(in: full, replacementString: text) {
            textView.replaceCharacters(in: full, with: text); textView.didChangeText()
            manager?.setActionName(action)
        }
        manager?.endUndoGrouping(); textView.breakUndoCoalescing(); select(selection)
    }

    @objc func gotoDocument(_ sender: Any?) {
        let position = EditorEditing.lineColumn(in: textView.string, offset: textView.selectedRange().location)
        let line = field("\(position.line)", placeholder: "Строка, с 1")
        let column = field("\(position.column)", placeholder: "Столбец, с 1")
        let alert = NSAlert(); alert.messageText = "Перейти к строке и столбцу"
        let stack = NSStackView(views: [row("Строка", line), row("Столбец", column)])
        stack.orientation = .vertical; stack.spacing = 8; stack.frame = NSRect(x: 0, y: 0, width: 420, height: 70)
        alert.accessoryView = stack; alert.addButton(withTitle: "Перейти"); alert.addButton(withTitle: "Отмена")
        alert.window.initialFirstResponder = line
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let offset = try EditorEditing.offset(in: textView.string, line: Int(line.stringValue) ?? 0, column: Int(column.stringValue) ?? 0)
            select(NSRange(location: offset, length: 0)); window?.makeFirstResponder(textView)
        } catch { showError("Позиция недоступна", error) }
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
        let full = NSRange(location: 0, length: text.utf16.count)
        textView.layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        guard text.utf8.count <= 256 * 1024, selectedSyntax != "none" else { return }
        let provider: (any EditorSyntaxProvider)?
        if let selectedSyntax { provider = EditorSyntaxRegistry.providers.first { $0.id == selectedSyntax } }
        else { provider = EditorSyntaxRegistry.provider(for: sourceURL?.lastPathComponent ?? "") }
        guard let provider else { return }
        let work = DispatchWorkItem { [weak self] in
            let spans = provider.highlights(text: text)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == revision, self.highlightGeneration == request else { return }
                for span in spans where NSMaxRange(span.range) <= full.length {
                    let color: NSColor
                    switch span.kind {
                    case .keyword: color = .systemPink
                    case .string: color = .systemGreen
                    case .number: color = .systemOrange
                    case .comment: color = .systemGray
                    case .literal: color = .systemTeal
                    }
                    self.textView.layoutManager?.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: span.range)
                }
            }
        }
        highlightWork = work; DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
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
        case (98, .shift): if let lastQuery { find(lastQuery, direction: .forward) } else { findDocument(nil) }
        case (98, .option): if let lastQuery { find(lastQuery, direction: .backward) } else { findDocument(nil) }
        case (100, .option): gotoDocument(nil) // F8
        case (99, .control): toggleLineNumbers(nil) // F3
        case (97, []): switchToViewer(nil) // F6
        case (109, .shift): if save() { window?.performClose(nil) } // Shift F10
        case (53, []), (109, []), (118, []): window?.performClose(nil) // Escape / F10 / F4
        default: return false
        }
        return true
    }
}
