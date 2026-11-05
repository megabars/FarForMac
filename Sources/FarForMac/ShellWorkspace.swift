import AppKit
import Darwin
import FarCore

/// Commands may use isolated processes or an explicitly enabled managed zsh.
/// Shell and panel directories synchronize only through the visible controls.
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
    /// URL, passive side, preserve the original history position.
    var navigateHistoryFolder: ((URL, Bool, Bool) -> Void)?
    var openFile: (URL, Bool) -> Void
    var showTerminal: () -> Void
    var togglePanels: () -> Void
    var refreshPanels: () -> Void
    var report: (String) -> Void
    private var session: TerminalSession?
    private var integration: PersistentShellIntegration?
    private var shellReady = false
    private var awaitingInitialPrompt = false
    private var terminalDraft = false
    private var promptActive = false
    private var pendingPromptClears = 0
    private var awaitingTypedCommand = false
    private enum CommandPhase { case entering, busy, continuation }
    private var commandPhase: CommandPhase = .entering
    private var managedInterrupt: Task<Void, Never>?
    private var inputAfterInterrupt: [Data] = []
    private var inputAfterInterruptBytes = 0
    private var smokeShellTrace: [String] = []
    private var shellDirectory: URL?
    private var pendingCommand: String?
    private var preparedRunning: PreparedUserCommand?
    private var preparedDraft: PreparedUserCommand?
    private let persistentMode = NSButton(checkboxWithTitle: L10n.text("Сохранять состояние shell"), target: nil, action: nil)
    private lazy var panelToShell = button(L10n.text("Папка панели → shell"), #selector(usePanelDirectory))
    private lazy var shellToPanel = button(L10n.text("Папка shell → панель"), #selector(useShellDirectory))
    private var sessionID = UUID()
    private var screen = TerminalScreen(columns: 100, rows: 30)
    private var history = CommandHistory()
    private var historyPosition = -1
    private var historyDraft = ""
    private var suppressFileHistoryPath: String?
    private var separateTerminals: [SeparateCommandTerminal] = []
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
    private var commandDirectory: URL { persistentMode.state == .on ? (shellDirectory ?? context().activeDirectory) : context().activeDirectory }

    init(context: @escaping () -> UserCommandContext, navigate: @escaping (URL) -> Void,
         openFile: @escaping (URL, Bool) -> Void, showTerminal: @escaping () -> Void,
         togglePanels: @escaping () -> Void, refreshPanels: @escaping () -> Void,
         report: @escaping (String) -> Void, loadHistory: Bool = true) {
        self.context = context; self.navigate = navigate; self.openFile = openFile
        self.showTerminal = showTerminal; self.togglePanels = togglePanels
        self.refreshPanels = refreshPanels; self.report = report
        super.init()
        if loadHistory {
            do { history = try CommandHistory.load(from: AppRuntime.historyURL) }
            catch { historyWritable = false; report("История не загружена; исходный файл сохранён: \(error.localizedDescription)") }
        } else { historyWritable = false }
        input.placeholderString = "Команда в активной папке · Enter — выполнить · Tab — путь"
        input.setAccessibilityLabel("Командная строка")
        input.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        input.delegate = self; input.target = self; input.action = #selector(runInput)
        let run = button("Выполнить", #selector(runInput))
        let historyButton = button("История…", #selector(commandHistory))
        let shell = button("Shell", #selector(interactiveShell))
        persistentMode.target = self; persistentMode.action = #selector(changeShellMode)
        persistentMode.toolTip = L10n.text("Отдельная сессия zsh сохраняет переменные и функции. Пользовательские startup-файлы не загружаются.")
        panelToShell.isEnabled = false; shellToPanel.isEnabled = false
        commandBar = inset(vertical([directoryLabel, horizontal([input, run, historyButton, shell], spacing: 8), horizontal([persistentMode, panelToShell, shellToPanel], spacing: 8)], spacing: 4), x: 16, y: 7)
        terminalText.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalText.backgroundColor = Palette.background; terminalText.textColor = Palette.text
        // Input is forwarded by TerminalTextView; native Paste must remain enabled.
        terminalText.isEditable = true; terminalText.isSelectable = true
        terminalText.isRichText = true; terminalText.isHorizontallyResizable = true
        terminalText.textContainer?.widthTracksTextView = false
        terminalText.textContainer?.containerSize = NSSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude)
        terminalText.autoresizingMask = [.width]
        terminalText.setAccessibilityLabel(L10n.text("Вывод терминала"))
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
        input.placeholderString = L10n.text(persistentMode.state == .on ? "Команда в папке shell · Enter — выполнить · Tab — путь" : "Команда в активной папке · Enter — выполнить · Tab — путь")
        if persistentMode.state == .on {
            directoryLabel.stringValue = "zsh: " + (shellDirectory?.path ?? url.path) + "  ·  " + L10n.text("Папка панели синхронизируется кнопками")
        } else {
            directoryLabel.stringValue = "\(url.path) >  ·  " + L10n.text("каждая команда — отдельный shell; cd меняет панель")
        }
        if record { recordActivity(.folder, value: url.path) }
    }
    func recordActivity(_ kind: ActivityHistoryKind, value: String, directory: String? = nil) {
        guard (kind != .view && kind != .edit) || suppressFileHistoryPath != value else { return }
        do { try history.record(kind: kind, value: value, directory: directory); saveHistory() }
        catch { report("История: \(error.localizedDescription)") }
    }
    func applyInterfacePreferences() {
        updateDirectory(); resizeTerminal()
        terminalText.textStorage?.setAttributedString(TerminalRenderer.render(screen, font: .monospacedSystemFont(ofSize: UIPreferences.fontSize(13), weight: .regular)))
    }
    func focusCommand() { input.window?.makeFirstResponder(input) }
    func focusTerminal() { terminalText.window?.makeFirstResponder(terminalText); resizeTerminal() }
    @objc private func panels() { togglePanels() }
    @objc private func runInput() {
        let command = input.stringValue
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if execute(command, directory: context().activeDirectory, recordHistory: preparedDraft?.isEphemeral != true) {
            preparedRunning = preparedDraft; preparedDraft = nil
            input.stringValue = ""; historyPosition = -1
            if !isRunning { preparedRunning?.cleanup(); preparedRunning = nil }
        }
    }
    @discardableResult
    func execute(_ command: String, directory: URL, recordHistory: Bool = true) -> Bool {
        if persistentMode.state == .on {
            do {
                _ = try PersistentShellIntegration.submission(command)
                if isRunning {
                    guard integration != nil, shellReady else { report(L10n.text("Shell занят. Завершите ввод или программу в терминале.")); showTerminal(); return false }
                    try submitPersistent(command)
                } else {
                    pendingCommand = command
                    try start(command: nil, directory: directory)
                }
                if recordHistory { recordActivity(.command, value: command, directory: shellDirectory?.path ?? directory.path) }
                return true
            } catch { pendingCommand = nil; report(error.localizedDescription); return false }
        }
        guard !isRunning else { report("Сначала завершите текущую PTY-сессию."); showTerminal(); return false }
        do {
            if let destination = try ShellCommand.directoryChange(in: command, currentDirectory: directory, previousDirectory: previousDirectory) {
                if recordHistory { recordActivity(.command, value: command, directory: directory.path) }; navigate(destination); return true
            }
            try start(command: command, directory: directory)
            if recordHistory { recordActivity(.command, value: command, directory: directory.path) }
            return true
        } catch { report(error.localizedDescription); return false }
    }
    @discardableResult
    private func executePrepared(_ prepared: PreparedUserCommand, directory: URL) -> Bool {
        guard execute(prepared.command, directory: directory, recordHistory: !prepared.isEphemeral) else { return false }
        if isRunning { preparedRunning = prepared }
        else { prepared.cleanup() }
        return true
    }
    @objc func interactiveShell() {
        showTerminal()
        if !isRunning { do { try start(command: nil, directory: context().activeDirectory) } catch { report(error.localizedDescription) } }
        focusTerminal()
    }
    private func start(command: String?, directory: URL) throws {
        let id = UUID(); sessionID = id
        cancelManagedInterrupt()
        integration?.cleanup(); integration = nil; shellReady = false; shellDirectory = nil; terminalDraft = false; awaitingInitialPrompt = false
        promptActive = false; pendingPromptClears = 0; awaitingTypedCommand = false; commandPhase = .entering
        let configuration: TerminalSession.Configuration
        if persistentMode.state == .on {
            let bridge = try PersistentShellIntegration(); integration = bridge; awaitingInitialPrompt = true
            configuration = bridge.configuration(directory: directory, columns: columns, rows: rows)
        } else {
            configuration = .init(command: command, directory: directory, columns: columns, rows: rows,
                                  environmentOverrides: ["TERM": "xterm-256color", "COLORTERM": "truecolor"])
        }
        screen = TerminalScreen(columns: columns, rows: rows)
        terminalText.string = ""; terminalStatus.stringValue = "PTY · \(directory.path) · \(command ?? "интерактивный shell")"
        let next = TerminalSession(configuration: configuration, onOutput: { [weak self] data in
            guard let self, self.sessionID == id else { return }; self.receive(data)
        }, onExit: { [weak self] result in
            guard let self, self.sessionID == id else { return }
            self.cancelManagedInterrupt()
            self.input.isEnabled = true; self.persistentMode.isEnabled = true
            self.shellReady = false; self.pendingCommand = nil; self.shellDirectory = nil
            self.promptActive = false; self.pendingPromptClears = 0; self.awaitingTypedCommand = false; self.terminalDraft = false
            self.integration?.cleanup(); self.integration = nil
            self.preparedRunning?.cleanup(); self.preparedRunning = nil
            self.panelToShell.isEnabled = false; self.shellToPanel.isEnabled = false
            self.updateDirectory()
            let outcome = result.signal.map { "сигнал \($0)" } ?? "код \(result.code ?? -1)"
            self.terminalStatus.stringValue = "PTY завершён: \(outcome) · Ctrl+O — вернуться к панелям"
            self.refreshPanels()
        })
        session = next
        do { try next.start() } catch { session = nil; integration?.cleanup(); integration = nil; throw error }
        persistentMode.isEnabled = false
        input.isEnabled = false; showTerminal(); focusTerminal()
    }
    private func receive(_ data: Data) {
        if let integration {
            for state in integration.consume(data) {
                traceShellStateForSmoke(state.clearedDraft ? "cleared" : state.ready ? "ready" : state.continuation ? "continuation" : "busy")
                if state.clearedDraft {
                    guard pendingPromptClears > 0 else { continue }
                    pendingPromptClears -= 1
                }
                if state.ready {
                    awaitingInitialPrompt = false
                    if !state.clearedDraft { awaitingTypedCommand = false; commandPhase = .entering }
                } else {
                    commandPhase = state.continuation ? .continuation : .busy
                }
                promptActive = state.ready && !awaitingTypedCommand
                shellReady = promptActive && !terminalDraft && pendingPromptClears == 0
                if let directory = state.directory { shellDirectory = directory }
                input.isEnabled = shellReady; panelToShell.isEnabled = shellReady; shellToPanel.isEnabled = shellReady && shellDirectory != nil
                if state.ready, pendingCommand == nil, !state.clearedDraft {
                    preparedRunning?.cleanup(); preparedRunning = nil
                }
                if shellReady {
                    terminalStatus.stringValue = "zsh · " + (shellDirectory?.path ?? "") + " · " + L10n.text("Код завершения") + ": \(state.exitCode ?? 0)"
                    updateDirectory(); refreshPanels()
                    if let command = pendingCommand {
                        pendingCommand = nil
                        do { try submitPersistent(command) } catch { report(error.localizedDescription) }
                    }
                } else if promptActive && terminalDraft {
                    terminalStatus.stringValue = L10n.text("Есть ввод в терминале · Ctrl+C — очистить строку и включить командную строку")
                }
            }
            if promptActive, managedInterrupt != nil { finishManagedInterrupt() }
        }
        screen.append(data)
        let responses = screen.takeResponses()
        if !responses.isEmpty { try? session?.send(responses) }
        terminalText.applicationCursorKeys = screen.applicationCursorKeys
        terminalText.bracketedPasteEnabled = screen.bracketedPasteEnabled
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }; self.renderScheduled = false
            self.terminalText.textStorage?.setAttributedString(TerminalRenderer.render(self.screen, font: .monospacedSystemFont(ofSize: UIPreferences.fontSize(13), weight: .regular)))
            self.terminalText.insertionPointColor = self.screen.cursorVisible ? Palette.text : .clear
            let cursor = NSRange(location: min(self.screen.cursorOffset, (self.terminalText.string as NSString).length), length: 0)
            self.terminalText.setSelectedRange(cursor)
            self.terminalText.scrollRangeToVisible(cursor)
        }
    }
    private func resizeTerminal() {
        let size = terminalScroll.contentSize
        guard size.width > 40, size.height > 40 else { return }
        let font = NSFont.monospacedSystemFont(ofSize: UIPreferences.fontSize(13), weight: .regular)
        let width = ("M" as NSString).size(withAttributes: [.font: font]).width
        let lineHeight = terminalText.layoutManager?.defaultLineHeight(for: font) ?? font.pointSize * 1.2
        let newColumns = max(10, min(400, Int((size.width - 12) / width)))
        let newRows = max(3, min(200, Int((size.height - 8) / lineHeight)))
        guard newColumns != columns || newRows != rows else { return }
        columns = newColumns; rows = newRows; screen.resize(columns: columns, rows: rows)
        if isRunning { do { try session?.resize(columns: columns, rows: rows) } catch { report(error.localizedDescription) } }
    }
    private func send(_ data: Data) {
        guard isRunning else { return }
        if integration != nil {
            guard !awaitingInitialPrompt else { NSSound.beep(); return }
            if data == Data([3]) {
                let foreground = session?.foregroundProcessGroup
                if promptActive || managedInterrupt != nil || commandPhase != .busy || foreground == nil
                    || (foreground == session?.processID && session?.interruptKeyIsInput != true) {
                    interrupt(); return
                }
                pendingPromptClears = 0
            }
            if managedInterrupt != nil {
                guard data.count <= 1_048_576 - inputAfterInterruptBytes else { report(TerminalSession.SessionError.inputBufferFull.localizedDescription); return }
                inputAfterInterrupt.append(data)
                inputAfterInterruptBytes += data.count
                return
            }
            let paste = data.starts(with: Data("\u{1b}[200~".utf8))
            let entered = !paste && data.contains(where: { $0 == 13 || $0 == 10 })
            if promptActive {
                // Only a standalone Enter ends a known prompt draft. A paste
                // containing newlines can leave unread text after a program.
                terminalDraft = paste || !(data == Data([13]) || data == Data([10]))
            } else {
                // Foreground programs need not read input. Keep the bar blocked
                // on return until Ctrl+C explicitly clears possible typeahead.
                terminalDraft = true
            }
            if entered && (promptActive || commandPhase == .continuation) {
                promptActive = false; awaitingTypedCommand = true; commandPhase = .entering
            }
            shellReady = false; input.isEnabled = false; panelToShell.isEnabled = false; shellToPanel.isEnabled = false
        }
        do { try session?.send(data) } catch { report(error.localizedDescription) }
    }
    private func submitPersistent(_ command: String) throws {
        guard shellReady else { throw TerminalSession.SessionError.notRunning }
        try session?.sendToForegroundShell(PersistentShellIntegration.submission(command))
        promptActive = false; awaitingTypedCommand = true; commandPhase = .entering
        shellReady = false; input.isEnabled = false; panelToShell.isEnabled = false; shellToPanel.isEnabled = false
        showTerminal(); focusTerminal()
    }
    @objc private func changeShellMode() {
        guard !isRunning else { persistentMode.state = integration == nil ? .off : .on; return }
        updateDirectory()
    }
    @objc private func usePanelDirectory() {
        guard shellReady else { return }
        do { try submitPersistent("builtin cd -- " + ShellCommand.quoteArgument(context().activeDirectory.path)) }
        catch { report(error.localizedDescription) }
    }
    @objc private func useShellDirectory() {
        guard shellReady, let directory = shellDirectory else { return }
        navigate(directory)
    }
    @objc private func interrupt() {
        do {
            // Clear through ZLE in input order; SIGINT may flush queued bytes.
            if integration == nil {
                try session?.interrupt()
            } else if promptActive {
                terminalDraft = false
                shellReady = false; input.isEnabled = false
                panelToShell.isEnabled = false; shellToPanel.isEnabled = false
                pendingPromptClears += 1
                do { try session?.send(PersistentShellIntegration.clearDraftInput) }
                catch { pendingPromptClears -= 1; throw error }
            } else if !awaitingInitialPrompt {
                if managedInterrupt != nil {
                    inputAfterInterrupt.removeAll(); inputAfterInterruptBytes = 0
                    return
                }
                pendingPromptClears = 0
                traceShellStateForSmoke("interrupt requested")
                managedInterrupt = Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.waitToInterruptManagedShell()
                }
            }
        } catch { report(error.localizedDescription) }
    }
    private func waitToInterruptManagedShell() async {
        let started = ProcessInfo.processInfo.systemUptime
        var handoffStarted: TimeInterval?
        var shellSignalled: TimeInterval?
        var shellSignals = 0
        defer { if !Task.isCancelled { finishManagedInterrupt() } }
        do {
            while !Task.isCancelled, isRunning, !promptActive {
                let now = ProcessInfo.processInfo.systemUptime
                guard now - started < 3 else { throw TerminalSession.SessionError.system("interrupt terminal", ETIMEDOUT) }
                if commandPhase != .entering, handoffStarted == nil { handoffStarted = now }
                // preexec precedes job control handoff. Give external jobs time
                // to take the PTY, while still allowing shell builtins and PS2
                // input to be interrupted when zsh remains the foreground group.
                let handoffElapsed = handoffStarted.map { now - $0 >= 0.04 } == true
                // A quoted Enter can stay inside ZLE without emitting a frame.
                let unconfirmedEditor = commandPhase == .entering
                let editorSettled = unconfirmedEditor && now - (shellSignalled ?? started) >= 0.25
                let allowShell = (shellSignals == 0 && handoffElapsed) || (shellSignals < 2 && editorSettled)
                if let target = try session?.interruptForeground(allowShell: allowShell) {
                    terminalDraft = false
                    traceShellStateForSmoke(target == .job ? "SIGINT job" : "SIGINT shell")
                    if target == .job {
                        // Prefer to replay in the new prompt. A job that handles
                        // SIGINT may stay active, so release its input after a bound.
                        try await Task.sleep(nanoseconds: 250_000_000)
                        return
                    }
                    shellSignalled = now
                    shellSignals += 1
                }
                // The job may acquire the PTY just after the shell was signalled.
                // Keep any subsequent input out of reach of a possible second flush.
                if let shellSignalled, now - shellSignalled >= 0.25, !unconfirmedEditor || shellSignals == 2 { return }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        } catch is CancellationError {
        } catch { report(error.localizedDescription) }
    }
    private func finishManagedInterrupt() {
        let queued = inputAfterInterrupt
        cancelManagedInterrupt()
        if promptActive && terminalDraft { interrupt() }
        for data in queued { send(data) }
    }
    private func cancelManagedInterrupt() {
        managedInterrupt?.cancel(); managedInterrupt = nil
        inputAfterInterrupt.removeAll(); inputAfterInterruptBytes = 0
    }
    private func traceShellStateForSmoke(_ event: String) {
        guard AppRuntime.isSmoke else { return }
        if smokeShellTrace.count == 24 { smokeShellTrace.removeFirst() }
        smokeShellTrace.append("\(event) shell=\(session?.processID ?? -1) fg=\(session?.foregroundProcessGroup ?? -1)")
    }
    @objc private func stop() { session?.stop() }
    func stopForExit() {
        cancelManagedInterrupt()
        configWindow?.finalizeClose()
        for terminal in separateTerminals { terminal.workspace?.stopForExit() }
        session?.forceStop(); integration?.cleanup(); pendingCommand = nil
        preparedRunning?.cleanup(); preparedRunning = nil; preparedDraft?.cleanup(); preparedDraft = nil
        historyQueue.sync {}
    }
    func confirmTermination() -> Bool {
        guard configWindow?.confirmClose() ?? true else { return false }
        guard isRunning || separateTerminals.contains(where: { $0.workspace?.isRunning == true }) else { return true }
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
        case #selector(NSResponder.cancelOperation(_:)): input.stringValue = ""; preparedDraft?.cleanup(); preparedDraft = nil; return true
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
        let value = input.stringValue, directory = commandDirectory
        completionGeneration += 1; let token = completionGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try ShellCommand.completePath(in: value, currentDirectory: directory) }
            DispatchQueue.main.async {
                guard let self else { return }; self.completing = false
                guard self.completionGeneration == token, self.input.stringValue == value, self.commandDirectory == directory else { return }
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
    private enum HistoryAction: Equatable { case open, shiftedOpen, insert, passiveFolder, view, edit }
    func showHistory(_ kind: ActivityHistoryKind, smokeKey: PanelListMenu.SmokeKey? = nil) {
        let title: String
        let kinds: Set<ActivityHistoryKind>
        let enterHint: String
        switch kind {
        case .command:
            title = "История команд"; kinds = [.command]
            enterHint = "Enter — выполнить · Shift+Enter — отдельно · Ctrl+Enter — вставить · F3 — папка запуска"
        case .folder:
            title = "История папок"; kinds = [.folder]
            enterHint = "Enter — перейти · Ctrl+Shift+Enter — пассивная панель · Ctrl+Enter — вставить · Ctrl+R — обновить"
        case .view, .edit:
            title = "История просмотра и правки"; kinds = [.view, .edit]
            enterHint = "Enter — открыть · F3 — просмотр · F4 — правка · Ctrl+Enter — вставить · Ctrl+R — обновить"
        }

        let menu = PanelListMenu(title: L10n.text(title), hint: enterHint +
            "\nIns — защита · Shift+Del — удалить запись · Del — очистить историю · Ctrl+C — копировать")
        var rows: [ActivityHistoryEntry] = []
        var selected: (ActivityHistoryEntry, HistoryAction)?
        func redraw(_ index: Int = 0) {
            rows = history.entries.filter { kinds.contains($0.kind) }
            menu.replaceRows(rows.map { entry in
                let mode: String
                switch entry.kind { case .view: mode = "F3  "; case .edit: mode = "F4  "; default: mode = "" }
                let text = entry.value.replacingOccurrences(of: "\r", with: "↵").replacingOccurrences(of: "\n", with: "↵")
                return .init(title: (entry.isLocked ? "◆  " : "   ") + mode + String(text.prefix(512)))
            }, selection: index)
        }
        func choose(_ entry: ActivityHistoryEntry, _ action: HistoryAction) {
            selected = (entry, action)
            menu.dismiss()
        }
        redraw()
        menu.onActivate = { index in choose(rows[index], .open) }
        menu.onKey = { [weak self] event in
            guard let self else { return false }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard let index = menu.selection, rows.indices.contains(index) else { return false }
            let entry = rows[index]
            switch event.keyCode {
            case 36, 76:
                if modifiers == .control { choose(entry, .insert) }
                else if modifiers == .shift { choose(entry, .shiftedOpen) }
                else if kind == .folder && modifiers == [.control, .shift] { choose(entry, .passiveFolder) }
                else { return false }
            case 99, 87:
                guard modifiers.isEmpty else { return false }
                if kinds.contains(.view) { choose(entry, .view) }
                else if kind == .command && event.keyCode == 99 {
                    let alert = NSAlert(); alert.messageText = "Каталог запуска команды"
                    alert.informativeText = entry.directory ?? "Каталог не записан."
                    alert.runModal()
                } else { return false }
            case 118:
                guard modifiers.isEmpty, kinds.contains(.edit) else { return false }
                choose(entry, .edit)
            case 114, 82:
                if modifiers.isEmpty {
                    self.history.toggleLock(id: entry.id); self.saveHistory(); redraw(index)
                } else if modifiers == .control {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.value, forType: .string)
                } else { return false }
            case 117, 65:
                if modifiers == .shift {
                    self.history.remove(id: entry.id)
                } else if modifiers.isEmpty {
                    let alert = NSAlert(); alert.messageText = "Очистить незащищённые записи истории?"
                    alert.addButton(withTitle: "Очистить"); alert.addButton(withTitle: "Отмена")
                    guard alert.runModal() == .alertFirstButtonReturn else { return true }
                    for target in kinds { self.history.clear(kind: target) }
                } else { return false }
                self.historyPosition = -1; self.saveHistory(); redraw(index)
            case 15:
                guard modifiers == .control, kind != .command else { return false }
                self.history.removeMissing(kinds: kinds); self.saveHistory(); redraw(index)
            case 8:
                guard modifiers == .control || modifiers == .command else { return false }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.value, forType: .string)
            default: return false
            }
            return true
        }
        menu.run(relativeTo: input.window, smokeKey: smokeKey)
        menu.onActivate = nil; menu.onKey = nil
        if let (entry, action) = selected { applyHistoryAction(action, entry: entry) }
    }

    private func applyHistoryAction(_ action: HistoryAction, entry: ActivityHistoryEntry) {
        if action == .insert { setCommand(entry.value); return }
        switch entry.kind {
        case .command:
            setCommand(entry.value)
            if action == .shiftedOpen { runSeparateHistoryCommand(entry.value) }
            else { runInput() }
        case .folder:
            let url = URL(fileURLWithPath: entry.value)
            if let navigateHistoryFolder { navigateHistoryFolder(url, action == .passiveFolder, action == .shiftedOpen) }
            else if action != .passiveFolder { navigate(url) }
        case .view, .edit:
            let editable = action == .edit || (action != .view && entry.kind == .edit)
            if action == .shiftedOpen { suppressFileHistoryPath = entry.value }
            defer { suppressFileHistoryPath = nil }
            openFile(URL(fileURLWithPath: entry.value), editable)
        }
    }

    private func runSeparateHistoryCommand(_ command: String) {
        let current = context(), directory = current.activeDirectory
        let terminal = SeparateCommandTerminal()
        let shell = ShellWorkspace(context: { current }, navigate: { _ in }, openFile: { _, _ in },
            showTerminal: { [weak terminal] in terminal?.showWindow(nil) },
            togglePanels: { [weak self] in self?.input.window?.makeKeyAndOrderFront(nil) },
            refreshPanels: refreshPanels, report: report, loadHistory: false)
        terminal.workspace = shell
        terminal.window?.contentView = shell.terminalView
        terminal.onClose = { [weak self, weak terminal] in self?.separateTerminals.removeAll { $0 === terminal } }
        do {
            try shell.start(command: command, directory: directory)
            separateTerminals.append(terminal)
            recordActivity(.command, value: command, directory: directory.path)
            input.stringValue = ""; historyPosition = -1
        } catch { report(error.localizedDescription) }
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
    private func setCommand(_ value: String, prepared: PreparedUserCommand? = nil) {
        if let prepared { preparedDraft?.cleanup(); preparedDraft = prepared }
        else if let draft = preparedDraft, !draft.listFiles.values.contains(where: { value.contains($0.path) }) {
            draft.cleanup(); preparedDraft = nil
        }
        input.stringValue = value; historyPosition = -1; focusCommand()
    }
    func showUserMenu(store: UserCommandStore? = nil, smokeKey: PanelListMenu.SmokeKey? = nil) {
        do {
            let ctx = context()
            let menu = try UserMenuOverlay(store: store ?? AppRuntime.commandStore, directory: ctx.activeDirectory)
            switch menu.run(relativeTo: input.window, smokeKey: smokeKey) {
            case .command(let template, let title):
                guard let prepared = try prepareUserCommand(template, title: title, context: ctx) else { return }
                executePrepared(prepared, directory: ctx.activeDirectory)
            case .editFile(let url):
                showCommandConfiguration(UserCommandStore(globalURL: url))
            case nil: break
            }
        } catch { report(error.localizedDescription) }
    }
    private func prepareUserCommand(_ template: String, title: String, context ctx: UserCommandContext) throws -> PreparedUserCommand? {
        guard persistentMode.state != .on || !isRunning || shellDirectory?.standardizedFileURL == ctx.activeDirectory.standardizedFileURL else {
            report(L10n.text("Для меню и ассоциаций сначала нажмите «Папка панели → shell»: команды относятся к файлам активной панели."))
            return nil
        }
        let parameters = try UserCommandExpander.inputs(in: template)
        guard let values = UserCommandParameterForm.collect(parameters, title: title) else { return nil }
        return try UserCommandExpander.prepare(template, context: ctx, inputValues: values)
    }
    private func previewCommand(_ template: String, title: String, source: String, overrideContext: UserCommandContext? = nil) {
        do {
            let ctx = overrideContext ?? context()
            guard let prepared = try prepareUserCommand(template, title: title, context: ctx) else { return }
            let expanded = prepared.command
            let runDirectory = ctx.activeDirectory
            let alert = NSAlert(); alert.messageText = title
            alert.informativeText = "Источник: \(source)\nКаталог: \(runDirectory.path)\n\n\(expanded)"
            alert.addButton(withTitle: "Выполнить"); alert.addButton(withTitle: "Вставить в строку"); alert.addButton(withTitle: "Отмена")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                executePrepared(prepared, directory: runDirectory)
            case .alertSecondButtonReturn: setCommand(expanded, prepared: prepared)
            default: break
            }
        } catch { report(error.localizedDescription) }
    }
    @objc func configureCommands() { showCommandConfiguration(AppRuntime.commandStore) }
    private func showCommandConfiguration(_ store: UserCommandStore) {
        if let configWindow, configWindow.window?.isVisible == true { configWindow.showWindow(nil); return }
        configWindow = UserCommandsWindow(store: store); configWindow?.showWindow(nil)
    }
    /// Exercises the same asynchronous prompt/state path as the command bar.
    static func runUISmokeChecks() async throws -> [String] {
        guard AppRuntime.isSmoke, let root = AppRuntime.smokeStateDirectory else { throw NetworkError.io("Shell smoke requires isolated state") }
        let child = root.appendingPathComponent("shell folder ' Юникод")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        var navigation: URL?, messages: [String] = []
        let workspace = ShellWorkspace(context: {
            UserCommandContext(currentFile: root.appendingPathComponent("fixture.txt"), markedFiles: [], activeDirectory: root, passiveDirectory: root)
        }, navigate: { navigation = $0 }, openFile: { _, _ in }, showTerminal: {}, togglePanels: {}, refreshPanels: {}, report: { messages.append($0) })
        defer { workspace.stopForExit() }
        workspace.persistentMode.state = .on; workspace.updateDirectory()
        func wait(_ step: String, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            while !condition() {
                guard Date() < deadline else {
                    let state = "ready=\(workspace.shellReady), prompt=\(workspace.promptActive), draft=\(workspace.terminalDraft), awaitingEnter=\(workspace.awaitingTypedCommand), clears=\(workspace.pendingPromptClears), interrupt=\(workspace.managedInterrupt != nil)"
                    let detail = (messages + workspace.smokeShellTrace).joined(separator: "; ")
                    throw NetworkError.io("Managed shell UI did not reach \(step) (\(state)): \(detail)\n" + workspace.screen.plainText)
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        guard workspace.execute("export FAR_UI_SMOKE_VALUE=retained; cd -- " + (try ShellCommand.quoteArgument(child.path)), directory: root) else { throw NetworkError.io("Could not start managed shell") }
        try await wait("prompt after initial command") { workspace.shellReady }
        guard navigation == nil, workspace.shellDirectory?.resolvingSymlinksInPath() == child.resolvingSymlinksInPath(), workspace.input.isEnabled,
              workspace.input.placeholderString == L10n.text("Команда в папке shell · Enter — выполнить · Tab — путь") else { throw NetworkError.io("Shell cwd must not move panels automatically") }
        workspace.previewCommand("printf '%s' {name}", title: "fixture", source: "smoke")
        guard messages.count == 1 else { throw NetworkError.io("Menu command must refuse a different shell directory") }
        workspace.useShellDirectory()
        guard navigation?.resolvingSymlinksInPath() == child.resolvingSymlinksInPath() else { throw NetworkError.io("Explicit shell-to-panel navigation failed") }
        workspace.usePanelDirectory(); try await wait("prompt after panel directory sync") { workspace.shellReady }
        guard workspace.shellDirectory?.resolvingSymlinksInPath() == root.resolvingSymlinksInPath() else { throw NetworkError.io("Explicit panel-to-shell cd failed") }
        workspace.send(Data("printf partial".utf8))
        guard !workspace.input.isEnabled, !workspace.panelToShell.isEnabled else { throw NetworkError.io("Partial terminal input must disable command-bar submissions") }
        workspace.interrupt(); try await wait("prompt after clearing partial input") { workspace.shellReady }
        workspace.send(Data("first draft".utf8)); workspace.interrupt()
        workspace.send(Data("new draft".utf8))
        try await wait("ordered clear acknowledgement") { workspace.pendingPromptClears == 0 && workspace.promptActive }
        guard !workspace.input.isEnabled else { throw NetworkError.io("Clear acknowledgement must not unlock a newly typed draft") }
        workspace.interrupt(); try await wait("prompt after clearing the second draft") { workspace.shellReady }
        workspace.send(Data("draft".utf8)); workspace.interrupt()
        workspace.send(Data("/bin/sleep 30\r".utf8)); workspace.interrupt()
        try await wait("prompt after rapid Enter and interrupt button") { workspace.shellReady }
        guard workspace.pendingPromptClears == 0 else { throw NetworkError.io("Interrupt after Enter must invalidate queued clear acknowledgements") }
        workspace.send(Data("draft".utf8)); workspace.interrupt()
        workspace.send(Data("/bin/sleep 30\r".utf8)); workspace.send(Data([3]))
        workspace.send(Data("discard this draft".utf8)); workspace.send(Data([3]))
        workspace.send(Data("printf 'INTERRUPT_DRAFT:%s\\n' kept".utf8))
        try await wait("editable prompt after rapid keyboard interrupt") { workspace.promptActive && workspace.managedInterrupt == nil }
        guard !workspace.input.isEnabled else { throw NetworkError.io("The draft typed after Ctrl+C must keep command-bar submissions blocked") }
        workspace.send(Data([13]))
        try await wait("execution of the draft typed after Ctrl+C") { workspace.shellReady }
        guard workspace.screen.plainText.contains("INTERRUPT_DRAFT:kept") else { throw NetworkError.io("The draft typed after Ctrl+C was lost") }
        workspace.send(Data("printf 'unfinished\r".utf8)); workspace.send(Data([3]))
        try await wait("prompt after interrupting a continuation") { workspace.shellReady }
        workspace.send(Data("draft".utf8)); workspace.send(Data([22])); workspace.send(Data([13])); workspace.send(Data([3]))
        try await wait("prompt after interrupting quoted Enter") { workspace.shellReady }
        guard workspace.execute("printf 'BUILTIN_%s\\n' WAITING; read farformac_value", directory: root) else { throw NetworkError.io("Shell builtin rejected") }
        try await wait("running shell builtin") { workspace.screen.plainText.contains("BUILTIN_WAITING") }
        workspace.interrupt(); try await wait("prompt after interrupting a shell builtin") { workspace.shellReady }
        let rawScript = "stty raw -echo; printf 'RAW_%s_READY\\n' BYTE; value=$(/usr/bin/od -An -tu1 -N1 | /usr/bin/tr -d '[:space:]'); stty sane; printf 'RAW_BYTE:%s\\n' \"$value\""
        guard workspace.execute("unsetopt monitor; /bin/sh -c " + (try ShellCommand.quoteArgument(rawScript)) + "; setopt monitor", directory: root) else {
            throw NetworkError.io("Raw terminal fixture rejected")
        }
        try await wait("raw program sharing shell process group") { workspace.screen.plainText.contains("RAW_BYTE_READY") }
        guard workspace.session?.foregroundProcessGroup == workspace.session?.processID,
              workspace.session?.interruptKeyIsInput == true else { throw NetworkError.io("Raw fixture did not share the shell group") }
        workspace.send(Data([3]))
        try await wait("raw program receiving Ctrl+C as a byte") { workspace.promptActive && workspace.screen.plainText.contains("RAW_BYTE:3") }
        workspace.interrupt(); try await wait("prompt after raw input") { workspace.shellReady }
        guard workspace.execute("printf 'VALUE:%s\\n' \"$FAR_UI_SMOKE_VALUE\"", directory: root) else { throw NetworkError.io("Second command rejected") }
        try await wait("prompt after reading persistent value") { workspace.shellReady }
        guard workspace.screen.plainText.contains("VALUE:retained") else { throw NetworkError.io("Managed shell did not preserve variable: " + workspace.screen.plainText) }
        guard workspace.execute("/bin/sh -c 'printf \"CHILD_%s_READY\\n\" RUNNING; exec /bin/cat'", directory: root) else { throw NetworkError.io("Foreground program rejected") }
        try await wait("foreground child start") { workspace.screen.plainText.contains("CHILD_RUNNING_READY") }
        workspace.send(Data("foreground input".utf8))
        guard !workspace.promptActive else { throw NetworkError.io("Foreground program must be interrupted, not sent a ZLE widget") }
        workspace.interrupt(); try await wait("prompt after foreground child interrupt") { workspace.shellReady }
        guard workspace.execute("/bin/sh -c 'printf \"SLEEP_%s_READY\\n\" INPUT; /bin/sleep 0.3'", directory: root) else { throw NetworkError.io("Sleep rejected") }
        try await wait("foreground sleep start") { workspace.screen.plainText.contains("SLEEP_INPUT_READY") }
        workspace.send(Data("unconsumed input".utf8))
        try await wait("prompt after foreground sleep with unread input") { workspace.promptActive }
        guard !workspace.input.isEnabled else { throw NetworkError.io("Unread foreground input must block command bar after normal exit") }
        workspace.interrupt(); try await wait("prompt after clearing foreground typeahead") { workspace.shellReady }
        workspace.send(Data("/bin/sleep 0.2\npartial".utf8))
        try await wait("prompt after unbracketed multiline paste") { workspace.promptActive }
        guard !workspace.input.isEnabled else { throw NetworkError.io("Unbracketed multiline paste must preserve unread tail protection") }
        workspace.interrupt(); try await wait("prompt after clearing the pasted tail") { workspace.shellReady }
        guard workspace.execute("exit", directory: root) else { throw NetworkError.io("Shell exit rejected") }
        try await wait("shell exit") { workspace.integration == nil && !workspace.isRunning }
        guard workspace.shellDirectory == nil, workspace.persistentMode.isEnabled else { throw NetworkError.io("Shell exit must clear cwd and reenable mode") }
        guard workspace.execute("printf 'NEW:%s\\n' \"${FAR_UI_SMOKE_VALUE-unset}\"", directory: root) else { throw NetworkError.io("New shell rejected") }
        try await wait("prompt in a fresh shell") { workspace.shellReady }
        guard workspace.screen.plainText.contains("NEW:unset") else { throw NetworkError.io("New shell leaked old state") }
        let prepared = try UserCommandExpander.prepare("cat {list}", context: workspace.context())
        let listURL = prepared.listFiles["list"]!
        guard workspace.executePrepared(prepared, directory: root), FileManager.default.fileExists(atPath: listURL.path) else {
            throw NetworkError.io("Prepared command must retain list files while running")
        }
        try await wait("prompt after command with prepared list files") { workspace.shellReady }
        guard workspace.screen.plainText.contains("fixture.txt"), !FileManager.default.fileExists(atPath: listURL.path), workspace.preparedRunning == nil else {
            throw NetworkError.io("Prepared list file must survive command execution and be cleaned at the next shell prompt")
        }
        let draft = try UserCommandExpander.prepare("cat {list0}", context: workspace.context())
        let draftURL = draft.listFiles["list0"]!
        workspace.setCommand(draft.command, prepared: draft)
        guard FileManager.default.fileExists(atPath: draftURL.path) else { throw NetworkError.io("Inserted list command lost its resources") }
        workspace.setCommand("printf replacement")
        guard !FileManager.default.fileExists(atPath: draftURL.path) else { throw NetworkError.io("Replacing an inserted command must clean unused list files") }
        return ["List files survive managed shell execution and are removed at prompt; replacing a draft releases its files", "Managed shell command bar preserves state without implicit panel navigation", "Shell directory sync is explicit and menu commands reject directory mismatch", "Partial terminal input blocks command bar and Ctrl+C restores prompt", "Rapid and repeated Ctrl+C preserve new input through job handoff, continuation and quoted Enter", "Raw programs sharing the shell group receive the Ctrl+C byte", "Shell exit clears cwd and a new session starts without old variables"] + (try await runMenuSmoke(in: root))
    }

    private static func runMenuSmoke(in root: URL) async throws -> [String] {
        let directory = root.appendingPathComponent("history-menu-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousWindow = NSApp.keyWindow
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 100),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        owner.title = "History menu fixture"
        owner.center()
        var opened: [(URL, Bool)] = []
        var folders: [(URL, Bool, Bool)] = []
        let workspace = ShellWorkspace(context: {
            UserCommandContext(currentFile: nil, markedFiles: [], activeDirectory: directory, passiveDirectory: directory)
        }, navigate: { _ in }, openFile: { opened.append(($0, $1)) }, showTerminal: {},
            togglePanels: {}, refreshPanels: {}, report: { _ in }, loadHistory: false)
        workspace.navigateHistoryFolder = { folders.append(($0, $1, $2)) }
        owner.contentView = workspace.commandBar
        owner.makeKeyAndOrderFront(nil)
        defer {
            for terminal in workspace.separateTerminals { terminal.close() }
            workspace.stopForExit()
            owner.close()
            previousWindow?.makeKeyAndOrderFront(nil)
            try? FileManager.default.removeItem(at: directory)
        }
        func waitForOutput(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            while !condition() {
                guard Date() < deadline else { throw NetworkError.io("Menu command did not produce fixture output") }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        let command = "printf 'HISTORY_%s' ENTER"
        try workspace.history.record(kind: .command, value: command, directory: "/")
        workspace.showHistory(.command, smokeKey: .init(code: 36, modifiers: .control))
        guard workspace.input.stringValue == command, !workspace.isRunning, owner.isKeyWindow else {
            throw NetworkError.io("Alt+F8 Ctrl+Enter must insert without launching and return focus")
        }
        workspace.showHistory(.command, smokeKey: .init(code: 36))
        try await waitForOutput { workspace.screen.plainText.contains("HISTORY_ENTER") && !workspace.isRunning }

        try workspace.history.record(kind: .command, value: "printf 'HISTORY_%s' SEPARATE")
        workspace.showHistory(.command, smokeKey: .init(code: 36, modifiers: .shift))
        guard let separate = workspace.separateTerminals.last, separate.window?.isVisible == true else {
            throw NetworkError.io("Alt+F8 Shift+Enter must open a separate terminal")
        }
        try await waitForOutput { separate.workspace?.screen.plainText.contains("HISTORY_SEPARATE") == true }
        guard !workspace.screen.plainText.contains("HISTORY_SEPARATE") else {
            throw NetworkError.io("The separate command changed the original terminal")
        }
        separate.close()
        owner.makeKeyAndOrderFront(nil)

        let file = directory.appendingPathComponent("fixture.txt")
        try Data("Fixture".utf8).write(to: file)
        try workspace.history.record(kind: .edit, value: file.path)
        workspace.showHistory(.view, smokeKey: .init(code: 36))
        let expectedFile = file.resolvingSymlinksInPath().path
        func openedDetails() -> String {
            opened.map { "\($0.0.path) (editable=\($0.1))" }.joined(separator: ", ")
        }
        guard opened.count == 1, opened[0].0.resolvingSymlinksInPath().path == expectedFile, opened[0].1 else {
            throw NetworkError.io("Alt+F11 Enter expected the edit entry \(expectedFile); received [\(openedDetails())]")
        }
        workspace.showHistory(.view, smokeKey: .init(code: 99, characters: String(UnicodeScalar(Int(NSF3FunctionKey))!), modifiers: .function))
        guard opened.count == 2, opened[1].0.resolvingSymlinksInPath().path == expectedFile, !opened[1].1 else {
            throw NetworkError.io("Alt+F11 F3 expected to reopen \(expectedFile) for viewing; received [\(openedDetails())]")
        }
        try workspace.history.record(kind: .folder, value: directory.path)
        workspace.showHistory(.folder, smokeKey: .init(code: 36, modifiers: [.control, .shift]))
        let expectedFolder = directory.resolvingSymlinksInPath().path
        guard folders.count == 1, folders[0].0.resolvingSymlinksInPath().path == expectedFolder, folders[0].1, !folders[0].2 else {
            let actual = folders.map { "\($0.0.path) (passive=\($0.1), preserveOrder=\($0.2))" }.joined(separator: ", ")
            throw NetworkError.io("Alt+F12 Ctrl+Shift+Enter expected passive navigation to \(expectedFolder); received [\(actual)]")
        }

        let store = UserCommandStore(globalURL: directory.appendingPathComponent("commands.json"))
        let configuration = UserCommandConfiguration(menu: [.init(title: "F2 fixture", command: "printf 'F2_%s' EXECUTED")])
        try store.saveGlobalText(String(decoding: JSONEncoder().encode(configuration), as: UTF8.self))
        workspace.showUserMenu(store: store, smokeKey: .init(code: 36))
        try await waitForOutput { workspace.screen.plainText.contains("F2_EXECUTED") && !workspace.isRunning }
        return ["History menu delivers Enter, Ctrl+Enter and Shift+Enter to the correct command modes",
                "Combined view/edit history and passive folder navigation receive menu keyboard actions",
                "F2 command runs after Enter without an intermediate preview"]
    }
    func alternativeAssociation(action: UserCommandAction) {
        guard let file = context().currentFile else { report(L10n.text("Выберите файл для альтернативной ассоциации.")); return }
        guard !association(for: file, action: action) else { return }
        switch action {
        case .alternateView, .view: openFile(file, false)
        case .alternateEdit, .edit: openFile(file, true)
        case .alternateExecute, .execute: NSWorkspace.shared.open(file)
        }
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
                    let explicit = UserCommandContext(currentFile: file, markedFiles: ctx.markedFiles, activeDirectory: ctx.activeDirectory, passiveDirectory: ctx.passiveDirectory, passiveCurrentFile: ctx.passiveCurrentFile, passiveMarkedFiles: ctx.passiveMarkedFiles)
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
    var applicationCursorKeys = false
    var bracketedPasteEnabled = false
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags.contains(.command) { super.keyDown(with: event); return }
        if flags == .control, event.keyCode == 31 { onToggle?(); return }
        if flags.contains(.control) {
            let codes: [UInt16: UInt8] = [0:1,11:2,8:3,2:4,14:5,3:6,5:7,4:8,34:9,38:10,40:11,37:12,46:13,45:14,31:15,35:16,12:17,15:18,1:19,17:20,32:21,9:22,13:23,7:24,16:25,6:26,33:27,42:28,30:29]
            if let byte = codes[event.keyCode] { onInput?(Data([byte])); return }
        }
        let keys: [UInt16:String] = [36:"\r",76:"\r",51:"\u{7f}",117:"\u{1b}[3~",48:"\t",53:"\u{1b}",123:"\u{1b}[D",124:"\u{1b}[C",125:"\u{1b}[B",126:"\u{1b}[A",115:"\u{1b}[H",119:"\u{1b}[F",116:"\u{1b}[5~",121:"\u{1b}[6~"]
        if let sequence = keys[event.keyCode] {
            let translated = applicationCursorKeys && [123,124,125,126,115,119].contains(event.keyCode) ? sequence.replacingOccurrences(of: "\u{1b}[", with: "\u{1b}O") : sequence
            onInput?(Data(translated.utf8)); return
        }
        interpretKeyEvents([event])
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let text = (insertString as? NSAttributedString)?.string ?? (insertString as? String) ?? ""
        onInput?(Data(text.utf8))
    }
    override func paste(_ sender: Any?) {
        if let value = NSPasteboard.general.string(forType: .string) { pasteText(value) }
    }
    func pasteText(_ value: String) {
            // Escape cannot terminate a bracketed paste and inject a second command.
            let clean = value.replacingOccurrences(of: "\u{1b}", with: "")
            onInput?(Data((bracketedPasteEnabled ? "\u{1b}[200~" + clean + "\u{1b}[201~" : clean).utf8))
    }
}

@MainActor private final class SeparateCommandTerminal: NSWindowController, NSWindowDelegate {
    var workspace: ShellWorkspace?
    var onClose: (() -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Терминал команды"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        workspace?.stopForExit()
        onClose?()
    }
}
