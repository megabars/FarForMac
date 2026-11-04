import AppKit
import FarCore

/// The command line uses a fresh shell for each command. An explicitly opened
/// interactive shell owns its cwd until it exits; it cannot silently move panels.
@MainActor
final class ShellWorkspace: NSObject, NSTextFieldDelegate {
    let input = NSTextField()
    let directoryLabel = label("", size: 11, color: Palette.muted)
    let terminalStatus = label("PTY · Ctrl+O — панели", size: 11, color: Palette.accent)
    let terminalText = TerminalTextView()
    let terminalScroll = NSScrollView()
    private(set) var commandBar: NSView!
    private(set) var terminalView: NSView!
    var context: () -> UserCommandContext
    var navigate: (URL) -> Void
    var openFile: (URL, Bool) -> Void
    var showTerminal: () -> Void
    var togglePanels: () -> Void
    var refreshPanels: () -> Void
    var report: (String) -> Void
    private var session: TerminalSession?
    private var sessionID = UUID()
    private var screen = TerminalScreen(columns: 100, rows: 30)
    private var history = CommandHistory()
    private var historyPosition = -1
    private var historyDraft = ""
    private var previousDirectory: URL?
    private var lastDirectory: URL?
    private var configWindow: UserCommandsWindow?
    private var renderScheduled = false
    private var columns = 100
    private var rows = 30
    private var completionGeneration = 0
    private var completing = false
    private var historyWritable = true
    private let historyQueue = DispatchQueue(label: "FarForMac.history", qos: .utility)
    var isRunning: Bool { session?.isRunning == true }

    init(context: @escaping () -> UserCommandContext, navigate: @escaping (URL) -> Void,
         openFile: @escaping (URL, Bool) -> Void, showTerminal: @escaping () -> Void,
         togglePanels: @escaping () -> Void, refreshPanels: @escaping () -> Void,
         report: @escaping (String) -> Void) {
        self.context = context; self.navigate = navigate; self.openFile = openFile
        self.showTerminal = showTerminal; self.togglePanels = togglePanels
        self.refreshPanels = refreshPanels; self.report = report
        super.init()
        do { history = try CommandHistory.load(from: AppRuntime.historyURL) } catch { historyWritable = false; report("История не загружена; исходный файл сохранён: \(error.localizedDescription)") }
        input.placeholderString = "Команда в активной папке · Enter — выполнить · Tab — путь"
        input.setAccessibilityLabel("Командная строка")
        input.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        input.delegate = self; input.target = self; input.action = #selector(runInput)
        let run = button("Выполнить", #selector(runInput))
        let historyButton = button("История…", #selector(commandHistory))
        let shell = button("Shell", #selector(interactiveShell))
        commandBar = inset(vertical([directoryLabel, horizontal([input, run, historyButton, shell], spacing: 8)], spacing: 4), x: 16, y: 7)
        terminalText.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalText.backgroundColor = Palette.background; terminalText.textColor = Palette.text
        // Input is forwarded by TerminalTextView; native Paste must remain enabled.
        terminalText.isEditable = true; terminalText.isSelectable = true
        terminalText.isRichText = false; terminalText.isHorizontallyResizable = true
        terminalText.textContainer?.widthTracksTextView = false
        terminalText.textContainer?.containerSize = NSSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude)
        terminalText.autoresizingMask = [.width]
        terminalText.onInput = { [weak self] data in self?.send(data) }
        terminalText.onToggle = { [weak self] in self?.togglePanels() }
        terminalScroll.documentView = terminalText
        terminalScroll.hasVerticalScroller = true; terminalScroll.hasHorizontalScroller = true
        terminalScroll.drawsBackground = false
        let controls = horizontal([terminalStatus, NSView(), button("Ctrl+C Прервать", #selector(interrupt)), button("Остановить", #selector(stop)), button("Ctrl+O Панели", #selector(panels))], spacing: 8)
        let content = vertical([inset(controls, x: 10, y: 7), terminalScroll])
        let host = TerminalHostView(); host.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: host.leadingAnchor), content.trailingAnchor.constraint(equalTo: host.trailingAnchor), content.topAnchor.constraint(equalTo: host.topAnchor), content.bottomAnchor.constraint(equalTo: host.bottomAnchor)])
        host.onLayout = { [weak self] in self?.resizeTerminal() }
        terminalView = host
        terminalView.setContentHuggingPriority(.defaultLow, for: .vertical)
    }
    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    func updateDirectory(record: Bool = false) {
        let url = context().activeDirectory
        completionGeneration += 1
        if lastDirectory != url { previousDirectory = lastDirectory; lastDirectory = url }
        directoryLabel.stringValue = "\(url.path) >  ·  каждая команда — отдельный shell; cd меняет панель"
        if record { recordActivity(.folder, value: url.path) }
    }
    func recordActivity(_ kind: ActivityHistoryKind, value: String, directory: String? = nil) {
        do { try history.record(kind: kind, value: value, directory: directory); saveHistory() }
        catch { report("История: \(error.localizedDescription)") }
    }
    func focusCommand() { input.window?.makeFirstResponder(input) }
    func focusTerminal() { terminalText.window?.makeFirstResponder(terminalText); resizeTerminal() }
    @objc private func panels() { togglePanels() }
    @objc private func runInput() {
        let command = input.stringValue
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if execute(command, directory: context().activeDirectory) { input.stringValue = ""; historyPosition = -1 }
    }
    @discardableResult
    func execute(_ command: String, directory: URL) -> Bool {
        guard !isRunning else { report("Сначала завершите текущую PTY-сессию."); showTerminal(); return false }
        do {
            if let destination = try ShellCommand.directoryChange(in: command, currentDirectory: directory, previousDirectory: previousDirectory) {
                recordActivity(.command, value: command, directory: directory.path); navigate(destination); return true
            }
            try start(command: command, directory: directory)
            recordActivity(.command, value: command, directory: directory.path)
            return true
        } catch { report(error.localizedDescription); return false }
    }
    @objc func interactiveShell() {
        showTerminal()
        if !isRunning { do { try start(command: nil, directory: context().activeDirectory) } catch { report(error.localizedDescription) } }
        focusTerminal()
    }
    private func start(command: String?, directory: URL) throws {
        let id = UUID(); sessionID = id
        screen = TerminalScreen(columns: columns, rows: rows)
        terminalText.string = ""; terminalStatus.stringValue = "PTY · \(directory.path) · \(command ?? "интерактивный shell")"
        let next = TerminalSession(configuration: .init(command: command, directory: directory, columns: columns, rows: rows), onOutput: { [weak self] data in
            guard let self, self.sessionID == id else { return }; self.receive(data)
        }, onExit: { [weak self] result in
            guard let self, self.sessionID == id else { return }
            self.input.isEnabled = true
            let outcome = result.signal.map { "сигнал \($0)" } ?? "код \(result.code ?? -1)"
            self.terminalStatus.stringValue = "PTY завершён: \(outcome) · Ctrl+O — вернуться к панелям"
            self.refreshPanels()
        })
        session = next
        do { try next.start() } catch { session = nil; throw error }
        input.isEnabled = false; showTerminal(); focusTerminal()
    }
    private func receive(_ data: Data) {
        screen.append(data)
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }; self.renderScheduled = false
            self.terminalText.string = self.screen.plainText
            let cursor = NSRange(location: min(self.screen.cursorOffset, (self.terminalText.string as NSString).length), length: 0)
            self.terminalText.setSelectedRange(cursor)
            self.terminalText.scrollRangeToVisible(cursor)
        }
    }
    private func resizeTerminal() {
        let size = terminalScroll.contentSize
        guard size.width > 40, size.height > 40 else { return }
        let width = ("M" as NSString).size(withAttributes: [.font: terminalText.font!]).width
        let newColumns = max(10, min(400, Int((size.width - 12) / width)))
        let newRows = max(3, min(200, Int((size.height - 8) / 16)))
        guard newColumns != columns || newRows != rows else { return }
        columns = newColumns; rows = newRows; screen.resize(columns: columns, rows: rows)
        if isRunning { do { try session?.resize(columns: columns, rows: rows) } catch { report(error.localizedDescription) } }
    }
    private func send(_ data: Data) {
        guard isRunning else { return }
        do { try session?.send(data) } catch { report(error.localizedDescription) }
    }
    @objc private func interrupt() { do { try session?.interrupt() } catch { report(error.localizedDescription) } }
    @objc private func stop() { session?.stop() }
    func stopForExit() { configWindow?.finalizeClose(); session?.forceStop(); historyQueue.sync {} }
    func confirmTermination() -> Bool {
        guard configWindow?.confirmClose() ?? true else { return false }
        guard isRunning else { return true }
        let alert = NSAlert(); alert.messageText = "Завершить работающую PTY-сессию?"
        alert.informativeText = "Команда или интерактивный shell будут остановлены при выходе."
        alert.addButton(withTitle: "Отмена"); alert.addButton(withTitle: "Завершить и выйти")
        return alert.runModal() == .alertSecondButtonReturn
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)): completePath(); return true
        case #selector(NSResponder.moveUp(_:)): previousCommand(backward: true); return true
        case #selector(NSResponder.moveDown(_:)): previousCommand(backward: false); return true
        case #selector(NSResponder.cancelOperation(_:)): input.stringValue = ""; return true
        default: return false
        }
    }
    func previousCommand(backward: Bool) {
        let commands = history.filtered(kind: .command)
        if historyPosition == -1 { historyDraft = input.stringValue }
        historyPosition = max(-1, min(commands.count - 1, historyPosition + (backward ? 1 : -1)))
        input.stringValue = historyPosition < 0 ? historyDraft : commands[historyPosition].value
        focusCommand()
    }
    func completePath() {
        guard !completing else { report("Дополнение пути ещё выполняется."); return }
        completing = true
        let value = input.stringValue, directory = context().activeDirectory
        completionGeneration += 1; let token = completionGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try ShellCommand.completePath(in: value, currentDirectory: directory) }
            DispatchQueue.main.async {
                guard let self else { return }; self.completing = false
                guard self.completionGeneration == token, self.input.stringValue == value, self.context().activeDirectory == directory else { return }
                do {
                    let completion = try result.get()
                    guard !completion.candidates.isEmpty else { self.report(completion.isTruncated ? "Достигнут предел просмотра папки. Уточните путь." : "Нет дополнений пути."); return }
                    if completion.candidates.count == 1 && !completion.isTruncated { self.setCommand(completion.candidates[0].commandLine); return }
                    let alert = NSAlert(); alert.messageText = "Дополнить путь"
                    alert.informativeText = completion.isTruncated ? "Показана ограниченная часть совпадений. Уточните путь при необходимости." : "Выберите путь; команда не будет выполнена."
                    let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 480, height: 26))
                    popup.addItems(withTitles: completion.candidates.map(\.path)); alert.accessoryView = popup
                    alert.addButton(withTitle: "Вставить"); alert.addButton(withTitle: "Отмена")
                    if alert.runModal() == .alertFirstButtonReturn { self.setCommand(completion.candidates[popup.indexOfSelectedItem].commandLine) }
                } catch { self.report(error.localizedDescription) }
            }
        }
    }
    @objc private func commandHistory() { showHistory(.command) }
    func showHistory(_ kind: ActivityHistoryKind) {
        let entries = history.filtered(kind: kind)
        guard !entries.isEmpty else { report("История пуста."); return }
        let titles: [ActivityHistoryKind: String] = [.command: "команды", .view: "просмотр", .edit: "редактор", .folder: "папки"]
        let alert = NSAlert(); alert.messageText = "История: \(titles[kind] ?? kind.rawValue)"
        alert.informativeText = kind == .command ? "Команда будет вставлена без выполнения; запуск — Enter в командной строке." : "Открыть выбранный объект или удалить записи истории."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 570, height: 26))
        popup.addItems(withTitles: entries.map { String($0.value.prefix(160)) }); alert.accessoryView = popup
        alert.addButton(withTitle: kind == .command ? "Вставить" : "Открыть")
        alert.addButton(withTitle: "Удалить запись"); alert.addButton(withTitle: "Очистить эту историю"); alert.addButton(withTitle: "Отмена")
        let response = alert.runModal(); let entry = entries[max(0, popup.indexOfSelectedItem)]
        switch response {
        case .alertFirstButtonReturn:
            switch kind {
            case .command: setCommand(entry.value)
            case .folder: navigate(URL(fileURLWithPath: entry.value))
            case .view, .edit: openFile(URL(fileURLWithPath: entry.value), kind == .edit)
            }
        case .alertSecondButtonReturn: history.remove(id: entry.id); historyPosition = -1; saveHistory()
        case .alertThirdButtonReturn: history.clear(kind: kind); historyPosition = -1; saveHistory()
        default: break
        }
    }
    private func saveHistory() {
        guard historyWritable else { return }
        let snapshot = history
        let historyURL = AppRuntime.historyURL
        historyQueue.async { [weak self] in
            do { try snapshot.save(to: historyURL) } catch { let message = error.localizedDescription; DispatchQueue.main.async { self?.report(message) } }
        }
    }
    func controlTextDidChange(_ notification: Notification) { historyPosition = -1 }
    private func setCommand(_ value: String) { input.stringValue = value; historyPosition = -1; focusCommand() }
    func showUserMenu() {
        do {
            let loaded = try AppRuntime.commandStore.loadMenu(in: context().activeDirectory)
            let menu = NSMenu(title: "Пользовательское меню")
            menu.addItem(withTitle: loaded.isLocal ? "Локальное: \(loaded.source.path)" : "Общее меню", action: nil, keyEquivalent: "")
            func append(_ entries: [UserMenuEntry], to menu: NSMenu) {
                for entry in entries {
                    let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                    if let children = entry.children { let nested = NSMenu(title: entry.title); append(children, to: nested); item.submenu = nested }
                    else if let command = entry.command {
                        item.target = self; item.action = #selector(menuCommand(_:)); item.representedObject = [command, loaded.source.path]
                        if let key = entry.key { item.keyEquivalent = key; item.keyEquivalentModifierMask = [] }
                    }
                    menu.addItem(item)
                }
            }
            append(loaded.entries, to: menu); menu.addItem(.separator())
            let configure = NSMenuItem(title: "Настроить общее меню и ассоциации…", action: #selector(configureCommands), keyEquivalent: ""); configure.target = self; menu.addItem(configure)
            menu.popUp(positioning: nil, at: NSPoint(x: 16, y: commandBar.bounds.height), in: commandBar)
        } catch { report(error.localizedDescription); configureCommands() }
    }
    @objc private func menuCommand(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [String], values.count == 2 else { return }
        previewCommand(values[0], title: sender.title, source: values[1])
    }
    private func previewCommand(_ template: String, title: String, source: String, overrideContext: UserCommandContext? = nil) {
        do {
            let ctx = overrideContext ?? context(); let expanded = try UserCommandExpander.expand(template, context: ctx)
            let alert = NSAlert(); alert.messageText = title
            alert.informativeText = "Источник: \(source)\nКаталог: \(ctx.activeDirectory.path)\n\n\(expanded)"
            alert.addButton(withTitle: "Выполнить"); alert.addButton(withTitle: "Вставить в строку"); alert.addButton(withTitle: "Отмена")
            switch alert.runModal() {
            case .alertFirstButtonReturn: execute(expanded, directory: ctx.activeDirectory)
            case .alertSecondButtonReturn: setCommand(expanded)
            default: break
            }
        } catch { report(error.localizedDescription) }
    }
    @objc func configureCommands() {
        if let configWindow, configWindow.window?.isVisible == true { configWindow.showWindow(nil); return }
        configWindow = UserCommandsWindow(store: AppRuntime.commandStore); configWindow?.showWindow(nil)
    }
    func association(for file: URL, action: UserCommandAction) -> Bool {
        do {
            let entries = try AppRuntime.commandStore.loadGlobal().matchingAssociations(for: file.lastPathComponent, action: action)
            guard !entries.isEmpty else { return false }
            let alert = NSAlert(); alert.messageText = "Ассоциация: \(file.lastPathComponent)"
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 480, height: 26)); popup.addItems(withTitles: entries.map(\.title)); alert.accessoryView = popup
            alert.addButton(withTitle: "Выбрать"); alert.addButton(withTitle: "Стандартное действие"); alert.addButton(withTitle: "Отмена")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if let template = entries[popup.indexOfSelectedItem].command(for: action) {
                    let ctx = context()
                    let explicit = UserCommandContext(currentFile: file, markedFiles: ctx.markedFiles, activeDirectory: ctx.activeDirectory, passiveDirectory: ctx.passiveDirectory)
                    previewCommand(template, title: entries[popup.indexOfSelectedItem].title, source: UserCommandStore.defaultGlobalURL.path, overrideContext: explicit)
                }
                return true
            case .alertSecondButtonReturn: return false
            default: return true
            }
        } catch { report(error.localizedDescription); return true }
    }
}

@MainActor private final class TerminalHostView: NSView {
    var onLayout: (() -> Void)?
    override func layout() { super.layout(); onLayout?() }
}

@MainActor final class TerminalTextView: NSTextView {
    var onInput: ((Data) -> Void)?
    var onToggle: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags.contains(.command) { super.keyDown(with: event); return }
        if flags == .control, event.keyCode == 31 { onToggle?(); return }
        if flags.contains(.control) {
            let codes: [UInt16: UInt8] = [0:1,11:2,8:3,2:4,14:5,3:6,5:7,4:8,34:9,38:10,40:11,37:12,46:13,45:14,31:15,35:16,12:17,15:18,1:19,17:20,32:21,9:22,13:23,7:24,16:25,6:26,33:27,42:28,30:29]
            if let byte = codes[event.keyCode] { onInput?(Data([byte])); return }
        }
        let keys: [UInt16:String] = [36:"\r",76:"\r",51:"\u{7f}",117:"\u{1b}[3~",48:"\t",53:"\u{1b}",123:"\u{1b}[D",124:"\u{1b}[C",125:"\u{1b}[B",126:"\u{1b}[A",115:"\u{1b}[H",119:"\u{1b}[F",116:"\u{1b}[5~",121:"\u{1b}[6~"]
        if let sequence = keys[event.keyCode] { onInput?(Data(sequence.utf8)); return }
        interpretKeyEvents([event])
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let text = (insertString as? NSAttributedString)?.string ?? (insertString as? String) ?? ""
        onInput?(Data(text.utf8))
    }
    override func paste(_ sender: Any?) {
        if let value = NSPasteboard.general.string(forType: .string) { onInput?(Data(value.utf8)) }
    }
}
