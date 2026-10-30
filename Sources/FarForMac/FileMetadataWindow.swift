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
    private let filename: String
    private let onSave: () -> Void

    init(directory: URL, filename: String, onSave: @escaping () -> Void) throws {
        guard directory.isFileURL else { throw FileDescriptionError.invalidName }
        self.filename = filename; self.onSave = onSave
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 390), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Описание — \(filename)"
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 500, height: 320); window.center()
        configureMetadataTextView(textView)
        busy = true; textView.isEditable = false; errorLabel.stringValue = "Загружаются описания…"
        let scroll = NSScrollView(); scroll.documentView = textView; scroll.hasVerticalScroller = true
        let intro = label("Описания хранятся в descript.ion этой папки (UTF-8). Пустой текст удаляет запись.", size: 11, color: Palette.muted)
        intro.maximumNumberOfLines = 2
        let save = NSButton(title: "Сохранить", target: self, action: #selector(saveDocument(_:))); save.bezelStyle = .rounded
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        let cancel = NSButton(title: "Отмена", target: self, action: #selector(cancelEditing)); cancel.bezelStyle = .rounded
        let actions = horizontal([NSView(), cancel, save])
        window.contentView = metadataContent(intro: intro, scroll: scroll, error: errorLabel, actions: actions)
        window.initialFirstResponder = textView
        configureEditing()
        Task { [weak self] in
            let result = await Task.detached { Result { try FileDescriptions.load(directory: directory) } }.value
            guard let self else { return }
            self.busy = false
            switch result {
            case .success(let snapshot):
                self.snapshot = snapshot; self.textView.string = snapshot.description(for: filename)
                self.textView.isEditable = true; self.errorLabel.stringValue = ""; self.markSaved()
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
        busy = true; saving = true; textView.isEditable = false; errorLabel.stringValue = "Сохраняется описание…"
        let edited = snapshot
        Task { [weak self] in
            let result = await Task.detached { Result { try edited.save() } }.value
            guard let self else { return }
            self.busy = false; self.saving = false; self.textView.isEditable = true
            switch result {
            case .success(let saved):
                self.snapshot = saved; self.markSaved(); self.errorLabel.stringValue = "Сохранено."
                self.onSave(); if closeAfterSave { self.close() }
            case .failure(let error): self.errorLabel.stringValue = error.localizedDescription
            }
        }
        return false
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
