import AppKit
import FarCore

/// Edits configuration and explicitly imports legacy menus; reading never executes commands.
@MainActor
final class UserCommandsWindow: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSUserInterfaceValidations {
    private let store: UserCommandStore
    private let onSave: () -> Void
    private let textView = NSTextView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var dirty = false
    private var pendingDiscard = false

    init(store: UserCommandStore = .init(), onSave: @escaping () -> Void = {}) {
        self.store = store; self.onSave = onSave
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Меню пользователя и ассоциации"
        window.isReleasedWhenClosed = false; window.delegate = self
        window.minSize = NSSize(width: 660, height: 500); window.center()

        let path = NSTextField(wrappingLabelWithString: store.globalURL.path)
        path.font = .monospacedSystemFont(ofSize: 11, weight: .regular); path.isSelectable = true
        let help = NSTextField(wrappingLabelWithString: "F2 открывает меню. Ассоциации: execute/view/edit и alternateExecute/alternateView/alternateEdit. Параметры {name}, {path}, {stem}, {extension}, {marked}, {active}, {passive}, {input:Название|текст}, {list}/{list0} — отдельные слова без своих кавычек. Конфигурация сама ничего не запускает.")
        help.font = .systemFont(ofSize: 12)
        let localHelp = NSTextField(wrappingLabelWithString: "Локальное меню: .farformac-menu.json в активной папке, тот же JSON с полями version и menu. Оно заменяет глобальное меню при F2; перед запуском показываются источник и готовая команда. Ассоциации берутся из глобальной конфигурации.")
        localHelp.font = .systemFont(ofSize: 11); localHelp.textColor = .secondaryLabelColor

        textView.isRichText = false; textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false; textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false; textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false; textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.allowsUndo = true
        textView.setAccessibilityLabel("JSON меню пользователя и ассоциаций")
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]; textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.documentView = textView
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        let example = NSButton(title: "Вставить пример", target: self, action: #selector(insertExample))
        let importMenu = NSButton(title: L10n.text("Импорт FarMenu.ini…"), target: self, action: #selector(importFarMenu))
        let validate = NSButton(title: "Проверить", target: self, action: #selector(validateText))
        let save = NSButton(title: "Сохранить", target: self, action: #selector(saveDocument(_:)))
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = [.command]
        let close = NSButton(title: "Закрыть", target: self, action: #selector(closeEditor))
        let actions = NSStackView(views: [example, importMenu, validate, NSView(), close, save]); actions.spacing = 10
        let content = NSView()
        for view in [path, help, localHelp, scroll, status, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            path.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            help.topAnchor.constraint(equalTo: path.bottomAnchor, constant: 9),
            localHelp.topAnchor.constraint(equalTo: help.bottomAnchor, constant: 6),
            scroll.topAnchor.constraint(equalTo: localHelp.bottomAnchor, constant: 12),
            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            actions.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 10),
            actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220)
        ] + [path, help, localHelp, scroll, status, actions].flatMap { view in [
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16)
        ] })
        window.contentView = content
        window.initialFirstResponder = textView
        do {
            if let text = try store.loadGlobalText() {
                textView.string = text
                status.stringValue = "Глобальная конфигурация загружена. Сохранение проверяет весь файл."
            } else {
                textView.string = UserCommandStore.example
                status.stringValue = "Файл ещё не создан. Пример появится в меню только после сохранения."
            }
        } catch {
            // Preserve malformed text for repair; a non-regular or oversized source cannot be opened.
            textView.string = ""
            status.stringValue = error.localizedDescription; status.textColor = .systemRed
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        focusEditor()
        // A menu action can finish tracking by restoring the previous key
        // window. Reassert ownership once that tracking action has returned.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.isVisible == true else { return }
            self.focusEditor()
        }
    }
    private func focusEditor() {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
    }
    func textDidChange(_ notification: Notification) {
        pendingDiscard = false; dirty = true; window?.isDocumentEdited = true
    }

    /// The standard nil-target File → Save action must resolve in this window's
    /// responder chain, just as it does for the document editor.
    @objc func saveDocument(_ sender: Any?) { saveText() }
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(saveDocument(_:)) { return true }
        return false
    }

    /// Called before application termination so a visible configuration editor
    /// gets the same save/discard/cancel decision as its close button.
    func confirmClose() -> Bool {
        pendingDiscard = false
        guard let window, window.isVisible else { return true }
        guard dirty else { return true }
        focusEditor()
        let alert = NSAlert(); alert.messageText = "Сохранить изменения конфигурации?"
        alert.addButton(withTitle: "Сохранить"); alert.addButton(withTitle: "Не сохранять"); alert.addButton(withTitle: "Отмена")
        switch alert.runModal() {
        case .alertFirstButtonReturn: saveText(); return !dirty
        case .alertSecondButtonReturn: pendingDiscard = true; return true
        default: return false
        }
    }

    /// Discard only once every application-level close guard has approved.
    /// A later PTY/document cancellation must leave this editor's buffer intact.
    func finalizeClose() {
        guard pendingDiscard else { return }
        pendingDiscard = false; dirty = false; window?.isDocumentEdited = false
        textView.string = (try? store.loadGlobalText()) ?? UserCommandStore.example
        setStatus("Несохранённые изменения отменены.")
    }

    private func setStatus(_ text: String, error: Bool = false) {
        status.stringValue = text; status.textColor = error ? .systemRed : .secondaryLabelColor
    }
    @objc private func validateText() {
        do {
            let config = try UserCommandConfiguration.decode(Data(textView.string.utf8))
            setStatus("Конфигурация корректна: \(config.menu.count) пунктов верхнего уровня, \(config.associations.count) ассоциаций. Команды не запускались.")
        } catch { setStatus(error.localizedDescription, error: true) }
    }
    @objc private func saveText() {
        do {
            try store.saveGlobalText(textView.string)
            pendingDiscard = false; dirty = false; window?.isDocumentEdited = false
            setStatus("Сохранено. Новые команды доступны при следующем открытии меню или вызове ассоциации.")
            onSave()
        } catch { setStatus(error.localizedDescription, error: true) }
    }
    @objc private func insertExample() {
        if !textView.string.isEmpty {
            let alert = NSAlert(); alert.messageText = "Заменить текст примером?"
            alert.informativeText = "Изменения в редакторе будут заменены. Сохранённый файл изменится только после нажатия «Сохранить»."
            alert.addButton(withTitle: "Заменить"); alert.addButton(withTitle: "Отмена")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        textView.string = UserCommandStore.example; pendingDiscard = false; dirty = true; window?.isDocumentEdited = true
        setStatus("Пример вставлен. Проверьте команды и сохраните конфигурацию.")
    }
    @objc private func importFarMenu() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = L10n.text("Выберите FarMenu.ini в UTF-8 или UTF-16. Импорт изменяет только текст редактора.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try store.importFarMenu(at: url)
            // Validate the current buffer before replacing anything, including associations.
            _ = try UserCommandConfiguration.decode(Data(textView.string.utf8))
            let alert = NSAlert(); alert.messageText = L10n.text("Заменить меню импортированным?")
            alert.informativeText = result.warnings.joined(separator: "\n\n")
            alert.addButton(withTitle: L10n.text("Импортировать")); alert.addButton(withTitle: L10n.text("Отмена"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try installImportedMenu(result)
        } catch { setStatus(error.localizedDescription, error: true) }
    }
    private func installImportedMenu(_ result: FarMenuImportResult) throws {
        var config = try UserCommandConfiguration.decode(Data(textView.string.utf8))
        config.menu = result.menu; try config.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(config)
        _ = try UserCommandConfiguration.decode(data)
        textView.string = String(decoding: data, as: UTF8.self)
        pendingDiscard = false; dirty = true; window?.isDocumentEdited = true
        setStatus(L10n.text("Меню импортировано в редактор. Ассоциации сохранены. Проверьте POSIX-команды и нажмите «Сохранить»."))
    }
    static func runUserCommandUISmokeChecks() throws -> [String] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FarCommandUI-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UserCommandStore(globalURL: directory.appendingPathComponent("commands.json"))
        let controller = UserCommandsWindow(store: store)
        defer { controller.window?.orderOut(nil) }
        let imported = try FarMenuImporter.parse(Data("F3: Inspect\n  printf '%s' !.!\n".utf8))
        try controller.installImportedMenu(imported)
        guard controller.dirty, controller.window?.isDocumentEdited == true,
              !FileManager.default.fileExists(atPath: store.globalURL.path) else { throw UserCommandError("Import must leave a dirty buffer without saving or execution") }
        let decoded = try UserCommandConfiguration.decode(Data(controller.textView.string.utf8))
        guard decoded.menu == imported.menu, !decoded.associations.isEmpty else { throw UserCommandError("Import must preserve associations") }
        controller.saveText()
        guard !controller.dirty, try store.loadGlobal().menu == imported.menu else { throw UserCommandError("Imported menu failed validated save") }
        let inputs = try UserCommandExpander.inputs(in: "printf '%s' {input:Search|default} {input:Other}")
        let form = UserCommandParameterForm(inputs: inputs)
        form.fields[0].stringValue = "O'Brien $(bad); Unicode ф"
        form.fields[1].stringValue = ""
        guard form.values[inputs[0].identifier] == form.fields[0].stringValue,
              form.values[inputs[1].identifier] == "", form.fields[0].accessibilityLabel() == "Search" else {
            throw UserCommandError("Interactive parameter form lost a value or accessibility label")
        }
        return ["FarMenu import changes the editor buffer and preserves associations until validated Save", "Interactive parameter fields preserve literal values, empty arguments and accessibility labels"]
    }
    @objc private func closeEditor() { window?.performClose(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard confirmClose() else { return false }
        finalizeClose()
        return true
    }
}

/// A single input dialog collects every unique parameter before command preview.
@MainActor
final class UserCommandParameterForm {
    let view: NSScrollView
    let fields: [NSTextField]
    private let inputs: [UserCommandInput]
    var values: [String: String] { Dictionary(uniqueKeysWithValues: zip(inputs, fields).map { ($0.identifier, $1.stringValue) }) }
    init(inputs: [UserCommandInput]) {
        self.inputs = inputs
        fields = inputs.map { input in
            let field = NSTextField(string: input.defaultValue)
            field.setAccessibilityLabel(input.title)
            field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            return field
        }
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        for (input, field) in zip(inputs, fields) {
            let label = NSTextField(wrappingLabelWithString: input.title)
            stack.addArrangedSubview(label); stack.addArrangedSubview(field)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let height = CGFloat(inputs.count) * 64 + 8
        let document = UserCommandParameterDocumentView(frame: NSRect(x: 0, y: 0, width: 470, height: height))
        stack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 4), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -4), stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 4)])
        view = NSScrollView(frame: NSRect(x: 0, y: 0, width: 490, height: min(420, height)))
        view.hasVerticalScroller = true; view.documentView = document; view.borderType = .bezelBorder
    }
    static func collect(_ inputs: [UserCommandInput], title: String) -> [String: String]? {
        guard !inputs.isEmpty else { return [:] }
        let form = UserCommandParameterForm(inputs: inputs)
        let alert = NSAlert(); alert.messageText = title
        alert.informativeText = L10n.text("Введите параметры. Каждое значение передаётся одним буквальным аргументом; команда появится для проверки следующим шагом.")
        alert.accessoryView = form.view
        alert.addButton(withTitle: L10n.text("Продолжить")); alert.addButton(withTitle: L10n.text("Отмена"))
        alert.window.initialFirstResponder = form.fields.first
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return form.values
    }
}

@MainActor private final class UserCommandParameterDocumentView: NSView {
    override var isFlipped: Bool { true }
}
