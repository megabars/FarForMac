import AppKit
import FarCore

@MainActor
class MetadataEditingWindow: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSUserInterfaceValidations, NSMenuItemValidation {
    let textView = NSTextView()
    let errorLabel = label("", size: 11, color: .systemRed)
    var busy = false
    var saving = false
    private var dirty = false
    private var pendingDiscard = false
    private var savedText = ""

    func configureEditing() {
        window?.delegate = self; textView.delegate = self
        textView.allowsUndo = true
    }
    func markSaved() {
        savedText = textView.string
        dirty = false; pendingDiscard = false; window?.isDocumentEdited = false
    }
    func textDidChange(_ notification: Notification) {
        dirty = textView.string != savedText; pendingDiscard = false; window?.isDocumentEdited = dirty
    }
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender); focusEditor()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.isVisible == true else { return }
            self.focusEditor()
        }
    }
    func focusEditor() { window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(textView) }
    @objc func saveDocument(_ sender: Any?) { _ = saveChanges(closeAfterSave: true) }
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        item.action == #selector(saveDocument(_:)) && !busy
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { validateUserInterfaceItem(menuItem) }
    @discardableResult func saveChanges(closeAfterSave: Bool) -> Bool { false }
    @objc func cancelEditing() { window?.performClose(nil) }
    func confirmClose() -> Bool {
        pendingDiscard = false
        guard window?.isVisible == true else { return true }
        guard !saving else { errorLabel.stringValue = "Дождитесь завершения сохранения."; return false }
        guard dirty else { return true }
        focusEditor()
        let alert = NSAlert(); alert.messageText = "Сохранить изменения?"
        alert.addButton(withTitle: "Сохранить"); alert.addButton(withTitle: "Не сохранять"); alert.addButton(withTitle: "Отмена")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveChanges(closeAfterSave: true) && !dirty
        case .alertSecondButtonReturn: pendingDiscard = true; return true
        default: return false
        }
    }
    func finalizeClose() {
        guard pendingDiscard else { return }
        textView.string = savedText; markSaved()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard confirmClose() else { return false }
        finalizeClose(); return true
    }
}

@MainActor
final class FileDescriptionWindow: MetadataEditingWindow {
    private var snapshot: FileDescriptions?
    private let directory: URL
    private let encodingPicker = NSPopUpButton()
    private var selectedEncoding: FileDescriptionEncoding
    private let filename: String
    private let onSave: () -> Void

    init(directory: URL, filename: String, onSave: @escaping () -> Void) throws {
        guard directory.isFileURL else { throw FileDescriptionError.invalidName }
        self.directory = directory; self.selectedEncoding = DescriptionPreferences.encoding(for: directory)
        self.filename = filename; self.onSave = onSave
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 390), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Описание — \(filename)"
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 500, height: 320); window.center()
        configureMetadataTextView(textView)
        busy = true; textView.isEditable = false; errorLabel.stringValue = "Загружаются описания…"
        let scroll = NSScrollView(); scroll.documentView = textView; scroll.hasVerticalScroller = true
        let intro = label("Описания хранятся в descript.ion. Кодировка выбирается явно и сохраняется без потери символов. Пустой текст удаляет запись.", size: 11, color: Palette.muted)
        intro.maximumNumberOfLines = 2
        let save = NSButton(title: "Сохранить", target: self, action: #selector(saveDocument(_:))); save.bezelStyle = .rounded
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        let cancel = NSButton(title: "Отмена", target: self, action: #selector(cancelEditing)); cancel.bezelStyle = .rounded
        encodingPicker.addItems(withTitles: FileDescriptionEncoding.allCases.map(\.title))
        encodingPicker.selectItem(at: FileDescriptionEncoding.allCases.firstIndex(of: selectedEncoding) ?? 0)
        encodingPicker.target = self; encodingPicker.action = #selector(changeEncoding)
        encodingPicker.setAccessibilityLabel(L10n.language == .english ? "Description file encoding" : "Кодировка файла описаний")
        let actions = horizontal([encodingPicker, NSView(), cancel, save])
        window.contentView = metadataContent(intro: intro, scroll: scroll, error: errorLabel, actions: actions)
        window.initialFirstResponder = textView
        configureEditing()
        reloadDescriptions()
    }
    @objc private func changeEncoding() {
        guard !busy else {
            encodingPicker.selectItem(at: FileDescriptionEncoding.allCases.firstIndex(of: selectedEncoding) ?? 0)
            return
        }
        if window?.isDocumentEdited == true {
            let alert = NSAlert()
            alert.messageText = L10n.language == .english ? "Discard edits and reread descriptions?" : "Отменить изменения и перечитать описания?"
            alert.addButton(withTitle: L10n.language == .english ? "Reread" : "Перечитать")
            alert.addButton(withTitle: L10n.text("Отмена"))
            guard alert.runModal() == .alertFirstButtonReturn else {
                encodingPicker.selectItem(at: FileDescriptionEncoding.allCases.firstIndex(of: selectedEncoding) ?? 0)
                return
            }
        }
        selectedEncoding = FileDescriptionEncoding.allCases[encodingPicker.indexOfSelectedItem]
        reloadDescriptions()
    }
    private func reloadDescriptions() {
        let directory = directory, encoding = selectedEncoding, filename = filename
        busy = true; snapshot = nil; textView.isEditable = false; encodingPicker.isEnabled = false
        errorLabel.stringValue = L10n.language == .english ? "Reading descriptions…" : "Загружаются описания…"
        Task { [weak self] in
            let result = await Task.detached { Result { try FileDescriptions.load(directory: directory, encoding: encoding) } }.value
            guard let self else { return }
            self.busy = false; self.encodingPicker.isEnabled = true
            switch result {
            case .success(let snapshot):
                self.snapshot = snapshot; self.textView.string = snapshot.description(for: filename)
                self.textView.isEditable = true; self.errorLabel.stringValue = ""; self.markSaved()
                DescriptionPreferences.setEncoding(encoding, for: directory)
                self.onSave()
            case .failure(let error): self.errorLabel.stringValue = error.localizedDescription
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        snapshot != nil && super.validateUserInterfaceItem(item)
    }
    @discardableResult override func saveChanges(closeAfterSave: Bool) -> Bool {
        guard !busy, var snapshot else { return false }
        do { try snapshot.setDescription(textView.string, for: filename) }
        catch { errorLabel.stringValue = error.localizedDescription; return false }
        busy = true; saving = true; encodingPicker.isEnabled = false; textView.isEditable = false; errorLabel.stringValue = "Сохраняется описание…"
        let edited = snapshot
        Task { [weak self] in
            let result = await Task.detached { Result { try edited.save() } }.value
            guard let self else { return }
            self.busy = false; self.saving = false; self.encodingPicker.isEnabled = true; self.textView.isEditable = true
            switch result {
            case .success(let saved):
                self.snapshot = saved; self.markSaved(); self.errorLabel.stringValue = "Сохранено."
                self.onSave(); if closeAfterSave { self.close() }
            case .failure(let error): self.errorLabel.stringValue = error.localizedDescription
            }
        }
        return false
    }
    static func runUISmokeChecks() async throws -> [String] {
        guard AppRuntime.isSmoke, let directory = AppRuntime.smokeStateDirectory else { throw ExtensionAPIError("Description smoke requires isolated state.") }
        let root = directory.appendingPathComponent("description-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("descript.ion")
        guard let original = "sample Старое\r\nkeep\t  Байты  \n".data(using: .windowsCP1251) else { throw ExtensionAPIError("Cannot encode description smoke fixture.") }
        try original.write(to: file)
        DescriptionPreferences.setEncoding(.utf8, for: root)
        let controller = try FileDescriptionWindow(directory: root, filename: "sample", onSave: {})
        controller.showWindow(nil); defer { controller.close() }
        func waitFor(_ check: () -> Bool) async throws {
            for _ in 0..<1_000 {
                if check() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw ExtensionAPIError("Description smoke timed out.")
        }
        try await waitFor { !controller.busy }
        guard controller.snapshot == nil, !controller.textView.isEditable,
              try Data(contentsOf: file) == original else { throw ExtensionAPIError("Wrong description encoding changed bytes or enabled editing.") }
        controller.encodingPicker.selectItem(at: 1); controller.changeEncoding()
        try await waitFor { !controller.busy }
        guard controller.snapshot?.encoding == .windows1251, controller.textView.string == "Старое",
              DescriptionPreferences.encoding(for: root) == .windows1251,
              try Data(contentsOf: file) == original else { throw ExtensionAPIError("Explicit legacy description selection failed or changed bytes.") }
        controller.textView.string = "Новое"
        _ = controller.saveChanges(closeAfterSave: false)
        try await waitFor { !controller.busy }
        let saved = try Data(contentsOf: file)
        guard saved == "sample Новое\r\nkeep\t  Байты  \n".data(using: .windowsCP1251),
              controller.snapshot?.description(for: "sample") == "Новое" else { throw ExtensionAPIError("Description save changed encoding or untouched bytes.") }
        controller.textView.string = "🙂"
        _ = controller.saveChanges(closeAfterSave: false)
        try await waitFor { !controller.busy }
        guard try Data(contentsOf: file) == saved, !controller.errorLabel.stringValue.isEmpty,
              controller.snapshot?.description(for: "sample") == "Новое" else { throw ExtensionAPIError("Unrepresentable description text was written or reported saved.") }
        controller.textView.string = "Новое"; controller.markSaved()
        controller.encodingPicker.selectItem(at: 0); controller.changeEncoding()
        try await waitFor { !controller.busy }
        guard controller.snapshot == nil, try Data(contentsOf: file) == saved,
              DescriptionPreferences.encoding(for: root) == .windows1251 else { throw ExtensionAPIError("Failed encoding selection changed bytes or remembered an invalid encoding.") }
        return ["Description editor explicitly rereads Windows-1251 without converting disk bytes", "Description editor saves original encoding and preserves unrelated formatting", "Description editor refuses emoji loss and does not persist a failed encoding choice"]
    }

}

@MainActor
final class SortGroupsWindow: MetadataEditingWindow {
    private let maskGroups: [String: String]
    private let onSave: (SortGroups) -> Void

    init(groups: SortGroups, maskGroups: [String: String], onSave: @escaping (SortGroups) -> Void) {
        self.maskGroups = maskGroups; self.onSave = onSave
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 750, height: 500), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Группы сортировки"
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 620, height: 380); window.center()
        configureMetadataTextView(textView)
        textView.string = (try? groups.jsonData()).flatMap { String(data: $0, encoding: .utf8) } ?? "{\n  \"enabled\": false,\n  \"upper\": [],\n  \"lower\": []\n}"
        let scroll = NSScrollView(); scroll.documentView = textView; scroll.hasVerticalScroller = true
        let intro = label("upper — перед остальными, lower — после. Одна маска в каждой строке массива.\nПервое совпадение побеждает; доступны <группы>. enabled включает порядок для имени и расширения.", size: 11, color: Palette.muted)
        intro.maximumNumberOfLines = 3
        let save = NSButton(title: "Сохранить", target: self, action: #selector(saveDocument(_:))); save.bezelStyle = .rounded
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        let cancel = NSButton(title: "Отмена", target: self, action: #selector(cancelEditing)); cancel.bezelStyle = .rounded
        let actions = horizontal([NSView(), cancel, save])
        window.contentView = metadataContent(intro: intro, scroll: scroll, error: errorLabel, actions: actions)
        window.initialFirstResponder = textView
        configureEditing(); markSaved()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @discardableResult override func saveChanges(closeAfterSave: Bool) -> Bool {
        do {
            let groups = try SortGroups.decode(Data(textView.string.utf8), maskGroups: maskGroups)
            onSave(groups); markSaved()
            if closeAfterSave { close() }; return true
        } catch { errorLabel.stringValue = error.localizedDescription; return false }
    }
}

@MainActor
private func configureMetadataTextView(_ text: NSTextView) {
    text.isRichText = false; text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
    text.isAutomaticTextReplacementEnabled = false; text.isAutomaticSpellingCorrectionEnabled = false
    text.textContainerInset = NSSize(width: 12, height: 12)
    text.autoresizingMask = [.width]; text.isVerticallyResizable = true
    text.textContainer?.widthTracksTextView = true
}

@MainActor
private func metadataContent(intro: NSTextField, scroll: NSScrollView, error: NSTextField, actions: NSStackView) -> NSView {
    error.maximumNumberOfLines = 3
    let content = NSView()
    for item in [intro, scroll, error, actions] { item.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(item) }
    NSLayoutConstraint.activate([
        intro.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), intro.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), intro.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
        scroll.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 12), scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
        error.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8), error.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), error.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
        actions.topAnchor.constraint(equalTo: error.bottomAnchor, constant: 12), actions.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), actions.trailingAnchor.constraint(equalTo: scroll.trailingAnchor), actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
    ])
    return content
}
