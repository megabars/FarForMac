import AppKit
import FarCore

/// AppKit adapter for the data-only command/macro contract.
@MainActor
final class CommandWorkspace: NSObject, NSMenuItemValidation {
    static let shared = CommandWorkspace()
    let registry = CommandRegistry()
    weak var mainWindow: NSWindow?
    var status: ((String) -> Void)?
    var panelKey: ((NSEvent) -> String?)?
    var panelState: (() -> MacroEnvironment?)?
    private var configuration = MacroConfiguration()
    private var playback: Task<Void, Never>?
    private weak var playbackWindow: NSWindow?
    private var mouseMonitor: Any?
    private var focusObserver: NSObjectProtocol?
    private(set) var bindingsEnabled = false
    lazy var macros = MacroController(registry: registry, environmentProvider: { [weak self] in
        guard let self else { return MacroEnvironment(context: .dialog) }
        if self.context == .editor, let editor = NSApp.keyWindow?.windowController as? TextFileWindow { return editor.macroEnvironment }
        if self.context == .viewer, let viewer = NSApp.keyWindow?.windowController as? ViewerWindow { return viewer.macroEnvironment }
        if self.context == .panel, let state = self.panelState?() { return state }
        return MacroEnvironment(context: self.context)
    }) { [weak self] in
        guard let self else { return .dialog }
        return self.context
    }
    var context: CommandContext {
        guard NSApp.modalWindow == nil, let key = NSApp.keyWindow, key.attachedSheet == nil else { return .dialog }
        if key.windowController is TextFileWindow { return .editor }
        if key.windowController is ViewerWindow { return .viewer }
        return key === mainWindow ? .panel : .dialog
    }
    private var acceptsMacroInput: Bool {
        guard !FarLuaWorkspace.shared.isRunning, !FarLuaWorkspace.shared.isRecording else { return false }
        guard context != .dialog else { return false }
        return MacroShortcutAdapter.acceptsInput(NSApp.keyWindow?.firstResponder)
    }
    private var storage: URL {
        AppRuntime.smokeStateDirectory?.appendingPathComponent("macros.json") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/FarForMac/macros.json")
    }
    func configure(window: NSWindow, status: @escaping (String) -> Void) {
        mainWindow = window; self.status = status
        if FileManager.default.fileExists(atPath: storage.path) {
            do { configuration = try MacroPersistence.load(from: storage) }
            catch { configuration = MacroConfiguration(); status("Не удалось прочитать макросы: \(error)") }
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if self?.playback != nil { self?.stopPlayback() }
            return event
        }
        // A focus change stops playback even when both windows share a context.
        focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.playback != nil, note.object as? NSWindow === self.playbackWindow else { return }
                self.macros.stop(); self.playback?.cancel()
            }
        }
    }
    func register(_ id: String, title: String, contexts: Set<CommandContext>, recordable: Bool = false, action: @escaping () throws -> Void) {
        do { try registry.register(id: CommandID(rawValue: id), title: title, contexts: contexts, recordable: recordable, handler: action) }
        catch { assertionFailure("Invalid command registration: \(id): \(error)") }
    }
    @discardableResult func dispatch(_ id: String) -> Bool {
        guard registry.descriptor(for: CommandID(rawValue: id)) != nil else { return false }
        do { try macros.execute(CommandID(rawValue: id), in: context) }
        catch { status?("Команда остановлена: \(id) — \(error)"); NSSound.beep() }
        return true
    }
    func installMenu(in bar: NSMenu) {
        let item = NSMenuItem(title: "Автоматизация", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: item.title); item.submenu = menu; bar.addItem(item)
        let browser = NSMenuItem(title: "LuaMacro: Macro Browser…", action: #selector(FarLuaWorkspace.showBrowser), keyEquivalent: "")
        browser.target = FarLuaWorkspace.shared; menu.addItem(browser)
        let load = NSMenuItem(title: "LuaMacro: загрузить Lua / MoonScript…", action: #selector(FarLuaWorkspace.importScript), keyEquivalent: "")
        load.target = FarLuaWorkspace.shared; menu.addItem(load)
        menu.addItem(.separator())
        for (title, action, key) in [
            ("Команды текущего окна…", #selector(palette), "p"),
            ("Начать запись макроса", #selector(startRecording), "r"),
            ("Завершить запись…", #selector(finishRecording), ""),
            ("Отменить запись", #selector(discardRecording), ""),
            ("Воспроизвести макрос…", #selector(playSelected), ""),
            ("Условия и повторы макроса…", #selector(editMacro), ""),
            ("Остановить макрос", #selector(stopPlayback), "."),
            ("Назначить клавишу…", #selector(assignBinding), ""),
            ("Удалить привязку…", #selector(removeBinding), ""),
            ("Включить / выключить привязки", #selector(toggleBindings), ""),
            ("Удалить макрос…", #selector(deleteMacro), ""),
            ("Импортировать макросы…", #selector(importMacros), ""),
            ("Экспортировать макросы…", #selector(exportMacros), ""),
            ("История ошибок…", #selector(showErrors), "")
        ] {
            let translated = title == "Удалить привязку…" ? macroText(title, "Remove binding…") : (title == "Условия и повторы макроса…" ? macroText(title, "Macro conditions and repeats…") : L10n.text(title))
            let entry = NSMenuItem(title: translated, action: action, keyEquivalent: key)
            entry.target = self; entry.keyEquivalentModifierMask = [.command, .control]; menu.addItem(entry)
        }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(stopPlayback): return playback != nil
        case #selector(finishRecording), #selector(discardRecording): return macros.isRecording
        case #selector(startRecording): return !macros.isRecording && playback == nil && acceptsMacroInput
        case #selector(toggleBindings): item.state = bindingsEnabled ? .on : .off; return playback == nil
        case #selector(showErrors): return playback == nil
        case #selector(playSelected): return playback == nil && !macros.isRecording && acceptsMacroInput
        case #selector(removeBinding): return playback == nil && !macros.isRecording && !configuration.bindings.isEmpty
        default: return playback == nil && !macros.isRecording || item.action == #selector(palette) && playback == nil
        }
    }
    /// Reserved shortcuts are handled before editor/viewer event monitors.
    func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .shift, .option])
        if flags == [.command, .control] {
            if event.keyCode == 47 { stopPlayback(); return true }
            if event.keyCode == 35 { palette(); return true }
            if event.keyCode == 15, macros.isRecording || acceptsMacroInput { macros.isRecording ? finishRecording() : startRecording(); return true }
        }
        if playback != nil { stopPlayback(); return true }
        if bindingsEnabled, !event.isARepeat, acceptsMacroInput,
           let binding = configuration.bindings.first(where: { $0.context == context && MacroShortcutAdapter.matches(event, $0) }),
           MacroShortcutAdapter.conflict(binding) == nil,
           let macro = configuration.macros.first(where: { $0.id == binding.macroID }) {
            play(macro); return true
        }
        guard NSApp.modalWindow == nil, NSApp.keyWindow?.attachedSheet == nil else { return false }
        if let editor = NSApp.keyWindow?.windowController as? TextFileWindow, let id = editor.automationKey(event) { return dispatch(id) }
        if let viewer = NSApp.keyWindow?.windowController as? ViewerWindow, let id = viewer.automationKey(event) { return dispatch(id) }
        if context == .panel, let id = panelKey?(event) { return dispatch(id) }
        return false
    }
    @objc private func palette() {
        let owner = NSApp.keyWindow, area = context
        let available = registry.descriptors.filter { $0.contexts.contains(area) }.sorted { $0.title < $1.title }
        guard !available.isEmpty, playback == nil else { return }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 580, height: 28))
        popup.addItems(withTitles: available.map { "\($0.title)  [\($0.id.rawValue)]\($0.recordable ? " • запись" : "")" })
        let alert = NSAlert(); alert.messageText = "Команды: \(area.rawValue)"
        alert.informativeText = "Точка «запись» обозначает команды, доступные для макросов. Диалоги, ввод текста, операции с файлами и фоновые задачи не записываются."
        alert.accessoryView = popup; alert.addButton(withTitle: "Выполнить"); alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        owner?.makeKeyAndOrderFront(nil); dispatch(available[popup.indexOfSelectedItem].id.rawValue)
    }
    @objc private func startRecording() {
        guard acceptsMacroInput else { return }
        do { try macros.startRecording(); status?("● Запись команд. Завершить: ⌃⌘R или меню «Автоматизация».") }
        catch { report(error) }
    }
    @objc private func finishRecording() {
        do {
            var macro = try macros.stopRecording(name: "Макрос")
            guard !macro.steps.isEmpty else { status?("Запись пуста: используйте команды с пометкой «запись»."); return }
            let field = NSTextField(string: "Макрос \(configuration.macros.count + 1)"); field.frame = NSRect(x: 0, y: 0, width: 400, height: 26)
            let alert = NSAlert(); alert.messageText = "Сохранить макрос — \(macro.steps.count) команд"
            alert.accessoryView = field; alert.addButton(withTitle: "Сохранить"); alert.addButton(withTitle: "Отмена")
            guard alert.runModal() == .alertFirstButtonReturn else { status?("Запись отменена."); return }
            macro.name = field.stringValue
            var proposed = configuration; proposed.macros.append(macro); try persist(proposed)
            status?("Макрос «\(macro.name)» сохранён.")
        } catch { report(error) }
    }
    @objc private func discardRecording() { macros.cancelRecording(); status?("Запись отменена.") }
    private func chooseMacro(_ title: String) -> CommandMacro? {
        guard !configuration.macros.isEmpty else { show("Макросов пока нет", "Начните запись через меню «Автоматизация»."); return nil }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 500, height: 28))
        popup.addItems(withTitles: configuration.macros.map { "\($0.name) — \($0.steps.count) команд" })
        let alert = NSAlert(); alert.messageText = title; alert.accessoryView = popup
        alert.addButton(withTitle: "Выбрать"); alert.addButton(withTitle: "Отмена")
        return alert.runModal() == .alertFirstButtonReturn ? configuration.macros[popup.indexOfSelectedItem] : nil
    }
    @objc private func playSelected() {
        let owner = NSApp.keyWindow
        guard let macro = chooseMacro("Воспроизвести макрос") else { return }
        owner?.makeKeyAndOrderFront(nil); play(macro)
    }
    private func play(_ macro: CommandMacro) {
        guard playback == nil, !macros.isRecording, acceptsMacroInput else { return }
        playbackWindow = NSApp.keyWindow
        status?("Воспроизведение: \(macro.name). Остановка: Esc / ⌃⌘.")
        playback = Task { [weak self] in
            guard let self else { return }
            defer { self.playback = nil; self.playbackWindow = nil }
            do { try await self.macros.play(macro); self.status?("Макрос «\(macro.name)» завершён.") }
            catch { self.status?("Макрос остановлен: \(error). Подробности — история ошибок.") }
        }
    }
    @objc func stopPlayback() { macros.stop(); playback?.cancel() }
    @objc private func toggleBindings() {
        if !bindingsEnabled {
            do { try validateBindings(configuration) } catch { report(error); return }
        }
        bindingsEnabled.toggle()
        status?(bindingsEnabled ? macroText("Привязки макросов включены до закрытия приложения.", "Macro shortcuts are enabled until the app quits.") : macroText("Привязки макросов выключены.", "Macro shortcuts are disabled."))
    }
    @objc private func assignBinding() {
        guard let macro = chooseMacro(macroText("Назначить клавишу макросу", "Assign a macro shortcut")), let area = macro.steps.first?.context else { return }
        do { try macros.validate(macro, in: area) } catch { report(error); return }
        let previous = configuration.bindings.first { $0.macroID == macro.id && $0.context == area }
        let key = NSTextField(string: previous?.key ?? "n")
        key.placeholderString = macroText("Латинская клавиша / F1…F20", "Latin key / F1…F20")
        key.setAccessibilityLabel(macroText("Клавиша на US-клавиатуре", "US keyboard key"))
        let modifierValues: [(MacroKeyModifier, String)] = [(.control, "Control ⌃"), (.option, "Option ⌥"), (.shift, "Shift ⇧"), (.command, "Command ⌘")]
        let modifiers = modifierValues.map { flag, title -> NSButton in
            let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            button.state = (previous?.modifiers ?? [.command, .control]).contains(flag) ? .on : .off
            return button
        }
        let row = NSStackView(views: modifiers); row.orientation = .horizontal; row.spacing = 14
        let contexts = CommandContext.allCases.filter { $0 != .dialog }
        let contextPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 470, height: 28))
        contextPopup.addItems(withTitles: contexts.map(contextTitle)); contextPopup.selectItem(at: contexts.firstIndex(of: area) ?? 0)
        contextPopup.setAccessibilityLabel(macroText("Контекст макроса", "Macro context"))
        let content = NSStackView(views: [key, row, contextPopup]); content.orientation = .vertical; content.alignment = .leading; content.spacing = 10
        content.frame = NSRect(x: 0, y: 0, width: 520, height: 110)
        key.widthAnchor.constraint(equalToConstant: 500).isActive = true
        while true {
            let alert = NSAlert(); alert.messageText = macroText("Привязка: ", "Shortcut: ") + macro.name
            alert.informativeText = macroText("Клавиша обозначает физическую позицию US-клавиатуры и не меняется при смене раскладки. Нужен Command и ещё один модификатор. Системные, меню и обычные команды редактирования защищены. Контекст должен совпадать с первой командой макроса. Назначение заменяет прежнюю привязку этого макроса в выбранном контексте. Включите привязки отдельно в меню.", "The key identifies a physical US keyboard position and stays the same when you switch input sources. Use Command with another modifier. System, menu and native editing shortcuts are protected. Context must match the first macro command. Assignment replaces this macro’s previous binding in the chosen context. Enable shortcuts separately in the menu.")
            alert.accessoryView = content; alert.addButton(withTitle: macroText("Назначить", "Assign")); alert.addButton(withTitle: L10n.text("Отмена"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            guard let name = MacroShortcutPolicy.canonicalKey(key.stringValue) else { show(alert.messageText, MacroShortcutAdapter.explanation(.invalidKey)); continue }
            let flags = Set(modifierValues.enumerated().compactMap { modifiers[$0.offset].state == .on ? $0.element.0 : nil })
            let binding = MacroKeyBinding(key: name, modifiers: flags, context: contexts[contextPopup.indexOfSelectedItem], macroID: macro.id)
            do {
                try MacroShortcutPolicy.validate(binding, in: configuration, replacingMacro: true)
                if let conflict = MacroShortcutAdapter.conflict(binding) { throw ExtensionAPIError(conflict) }
                var proposed = configuration
                proposed.bindings.removeAll { $0.macroID == macro.id && $0.context == binding.context }
                proposed.bindings.append(binding); try persist(proposed)
                status?(macroText("Назначена клавиша: ", "Assigned shortcut: ") + MacroShortcutAdapter.label(binding) + " · " + contextTitle(binding.context))
                return
            } catch let error as MacroBindingError { show(alert.messageText, MacroShortcutAdapter.explanation(error)) }
            catch { report(error) }
        }
    }
    @objc private func removeBinding() {
        guard !configuration.bindings.isEmpty else { return }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 540, height: 28))
        popup.addItems(withTitles: configuration.bindings.map { binding in
            let name = configuration.macros.first { $0.id == binding.macroID }?.name ?? "?"
            return MacroShortcutAdapter.label(binding) + " · " + contextTitle(binding.context) + " — " + name
        })
        let alert = NSAlert(); alert.messageText = macroText("Удалить привязку", "Remove shortcut")
        alert.informativeText = macroText("Макрос сохранится. В другом контексте та же клавиша останется назначенной.", "The macro is kept. Bindings for the same key in other contexts are kept.")
        alert.accessoryView = popup; alert.addButton(withTitle: macroText("Удалить привязку", "Remove shortcut")); alert.addButton(withTitle: L10n.text("Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var proposed = configuration; proposed.bindings.remove(at: popup.indexOfSelectedItem)
        do { try persist(proposed); status?(macroText("Привязка удалена.", "Shortcut removed.")) } catch { report(error) }
    }
    private func contextTitle(_ context: CommandContext) -> String {
        switch context {
        case .panel: return macroText("Панели", "Panels")
        case .editor: return macroText("Редактор", "Editor")
        case .viewer: return macroText("Просмотрщик", "Viewer")
        case .dialog: return macroText("Диалог", "Dialog")
        }
    }
    @objc private func editMacro() {
        guard let macro = chooseMacro(macroText("Условия и повторы макроса", "Macro conditions and repeats")) else { return }
        let form = MacroEditorForm(macro: macro)
        while true {
            let alert = NSAlert(); alert.messageText = macro.name
            alert.informativeText = macroText("Условия проверяются до первой команды. Выбор — пометки панели или выделенный текст. Каждый повтор проверяет контекст и остановку. Общий предел — 256 выполнений команд.", "Conditions are checked before the first command. Selection means marked panel entries or selected text. Each repeat checks context and cancellation. The total limit is 256 command executions.")
            alert.accessoryView = form.content
            alert.addButton(withTitle: L10n.text("Сохранить")); alert.addButton(withTitle: L10n.text("Отмена"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do {
                let updated = try form.updatedMacro()
                var proposed = configuration
                guard let index = proposed.macros.firstIndex(where: { $0.id == macro.id }) else { return }
                proposed.macros[index] = updated; try persist(proposed)
                return
            } catch { report(error) }
        }
    }
    static func runUISmokeChecks() throws -> [String] {
        let macro = CommandMacro(name: "Conditions smoke", steps: [MacroStep(commandID: "panel.next", context: .panel)])
        let form = MacroEditorForm(macro: macro)
        form.mask.stringValue = "*.txt|secret*"
        form.selection.selectItem(at: 1)
        form.repeats[0].stringValue = "3"
        let changed = try form.updatedMacro()
        guard changed.steps[0].repeatCount == 3,
              try changed.conditions?.matches(MacroEnvironment(context: .panel, fileName: "hello.txt", hasSelection: true)) == true,
              try changed.conditions?.matches(MacroEnvironment(context: .panel, fileName: "secret.txt", hasSelection: true)) == false,
              try changed.conditions?.matches(MacroEnvironment(context: .panel, fileName: "hello.txt", hasSelection: false)) == false else {
            throw ExtensionAPIError("Macro condition form did not preserve mask, selection and repeat controls.")
        }
        form.repeats[0].stringValue = "257"
        do { _ = try form.updatedMacro(); throw ExtensionAPIError("Macro form accepted an unbounded repeat.") }
        catch MacroError.invalidConfiguration {}
        return ["Macro condition controls preserve filename exclusions, selection and repeats", "Macro repeat form rejects more than 256 executions"]
    }
    @objc private func deleteMacro() {
        guard let macro = chooseMacro("Удалить макрос") else { return }
        var proposed = configuration; proposed.macros.removeAll { $0.id == macro.id }; proposed.bindings.removeAll { $0.macroID == macro.id }
        do { try persist(proposed) } catch { report(error) }
    }
    @objc private func importMacros() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try MacroPersistence.load(from: url)
            try validateBindings(imported)
            let alert = NSAlert(); alert.messageText = "Заменить список макросов?"
            alert.informativeText = "Макросов: \(imported.macros.count). Загрузка не запускает команды. Привязки будут выключены; включение доступно отдельно. Lua-файлы FAR не поддерживаются."
            alert.addButton(withTitle: "Импортировать"); alert.addButton(withTitle: "Отмена")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try persist(imported); bindingsEnabled = false
        } catch { report(error) }
    }
    @objc private func exportMacros() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "FarForMac-macros.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try MacroPersistence.save(configuration, to: url) } catch { report(error) }
    }
    @objc private func showErrors() {
        show("История ошибок макросов", macros.errors.isEmpty ? "Ошибок нет." : macros.errors.prefix(20).map { "\($0.date.formatted()) · \($0.commandID?.rawValue ?? "макрос")\n\($0.message)" }.joined(separator: "\n\n"))
    }
    private func validateBindings(_ value: MacroConfiguration) throws {
        try value.validate()
        for binding in value.bindings {
            if let conflict = MacroShortcutAdapter.conflict(binding) {
                throw ExtensionAPIError(MacroShortcutAdapter.label(binding) + ": " + conflict)
            }
        }
    }
    private func persist(_ proposed: MacroConfiguration) throws {
        try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try MacroPersistence.save(proposed, to: storage); configuration = proposed
    }
    private func report(_ error: Error) { show(L10n.text("Автоматизация"), (error as? LocalizedError)?.errorDescription ?? String(describing: error)) }
    private func show(_ title: String, _ message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.addButton(withTitle: L10n.text("Закрыть")); alert.runModal()
    }
}

/// Shared by the real modal editor and AppKit smoke checks.
@MainActor
private final class MacroEditorForm {
    let content: NSStackView
    let mask: NSTextField
    let selection: NSPopUpButton
    let kind: NSPopUpButton
    let editable: NSPopUpButton
    let repeats: [NSTextField]
    private let macro: CommandMacro
    init(macro: CommandMacro) {
        self.macro = macro
        let conditions = macro.conditions ?? MacroConditions()
        mask = NSTextField(string: conditions.fileMask ?? "")
        mask.placeholderString = macroText("Пусто — любое имя; например *.txt|secret*", "Empty matches any name; e.g. *.txt|secret*")
        mask.setAccessibilityLabel(macroText("Маска имени файла", "Filename mask"))
        selection = Self.popup([macroText("Любой выбор", "Any selection"), macroText("Есть выбор", "Selection present"), macroText("Нет выбора", "No selection")], index: MacroRequirement.allCases.firstIndex(of: conditions.selection) ?? 0)
        kind = Self.popup([macroText("Файл или папка", "File or folder"), macroText("Только файл", "Files only"), macroText("Только папка", "Folders only")], index: MacroEntryKind.allCases.firstIndex(of: conditions.entryKind) ?? 0)
        editable = Self.popup([macroText("Любой режим редактирования", "Any editing mode"), macroText("Редактирование разрешено", "Editable"), macroText("Только чтение", "Read only")], index: MacroRequirement.allCases.firstIndex(of: conditions.editable) ?? 0)
        let repeatFields = macro.steps.enumerated().map { index, step in
            let field = NSTextField(string: String(step.repeatCount))
            field.setAccessibilityLabel(macroText("Повтор шага", "Step repeat") + " \(index + 1) · \(step.commandID.rawValue)")
            field.widthAnchor.constraint(equalToConstant: 60).isActive = true
            return field
        }
        repeats = repeatFields
        let rows = NSStackView(views: macro.steps.enumerated().map { index, step in
            let label = NSTextField(labelWithString: "\(index + 1). \(step.commandID.rawValue)")
            let row = NSStackView(views: [label, repeatFields[index]]); row.spacing = 12; row.distribution = .fill
            label.widthAnchor.constraint(equalToConstant: 430).isActive = true
            return row
        })
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 6
        rows.setFrameSize(NSSize(width: 520, height: CGFloat(max(1, macro.steps.count)) * 30))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 160))
        scroll.documentView = rows; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        content = NSStackView(views: [NSTextField(labelWithString: macroText("Маска имени файла:", "Filename mask:")), mask, selection, kind, editable,
                                    NSTextField(labelWithString: macroText("Повторы команд (1–256):", "Command repeats (1–256):")), scroll])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 8
        content.setFrameSize(NSSize(width: 540, height: 350))
        mask.widthAnchor.constraint(equalToConstant: 530).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 540).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 160).isActive = true
    }
    private static func popup(_ titles: [String], index: Int) -> NSPopUpButton {
        let popup = NSPopUpButton(); popup.addItems(withTitles: titles); popup.selectItem(at: index)
        popup.setAccessibilityLabel(titles.first ?? "")
        return popup
    }
    func updatedMacro() throws -> CommandMacro {
        var result = macro
        let pattern = mask.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        result.conditions = MacroConditions(fileMask: pattern.isEmpty ? nil : pattern,
                                            entryKind: MacroEntryKind.allCases[kind.indexOfSelectedItem],
                                            selection: MacroRequirement.allCases[selection.indexOfSelectedItem],
                                            editable: MacroRequirement.allCases[editable.indexOfSelectedItem])
        for index in result.steps.indices {
            guard let value = Int(repeats[index].stringValue) else { throw MacroError.invalidConfiguration }
            result.steps[index].repeatCount = value
        }
        try MacroConfiguration(macros: [result]).validate()
        return result
    }
}
