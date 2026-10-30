import AppKit
import FarCore

/// Owns the JSON editor only; menu rendering and explicit execution belong to AppDelegate.
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
        let help = NSTextField(wrappingLabelWithString: "F2 открывает меню. Ассоциации задают execute, view и edit для маски файлов. Параметры {name}, {path}, {marked}, {active}, {passive} вставляются с POSIX-кавычками: пишите их отдельными словами без своих кавычек. Конфигурация сама ничего не запускает.")
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
        let validate = NSButton(title: "Проверить", target: self, action: #selector(validateText))
        let save = NSButton(title: "Сохранить", target: self, action: #selector(saveDocument(_:)))
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = [.command]
        let close = NSButton(title: "Закрыть", target: self, action: #selector(closeEditor))
        let actions = NSStackView(views: [example, validate, NSView(), close, save]); actions.spacing = 10
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
    @objc private func closeEditor() { window?.performClose(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard confirmClose() else { return false }
        finalizeClose()
        return true
    }
}
