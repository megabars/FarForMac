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
    var navigateMenuDirectory: ((URL, Bool, @escaping (Bool) -> Void) -> Void)?
    var navigateInternalDirectory: ((URL, Bool, Bool, @escaping (Bool) -> Void) -> Void)?
    var executePluginCommand: ((String, String, URL) -> Bool)?
    var pluginCommandBusy: (() -> Bool)?
    var pluginCommandFailure: (() -> String?)?
    var cancelPluginCommand: (() -> Void)?
    var executeFarCommand: ((InternalFarCommand) -> Bool)?
    var setCommandTitle: ((String?) -> Void)?
    var exitFromCommand: ((Int32) -> Void)?
    var showUserMenuHelp: (() -> Void)?
    var showUserMenuPlugins: (() -> Void)?
    var promptNetworkPath: (() -> String?)?
    var farCmdsEnvironment: [String: String] { commandState.environment }
    func appendFarCmdsOutput(_ data: Data) { screen.append(data); scheduleTerminalRender() }
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
    private var pendingCommandEcho = true
    private var appliedEnvironmentOverrides: [String: String] = [:]
    private var appliedEnvironmentRemovals: Set<String> = []
    private var commandState = InternalCommandState()
    private var navigatingInternalCommand = false
    private var preparedRunning: PreparedUserCommand?
    private var preparedDraft: PreparedUserCommand?
    private var preparedPlugin: PreparedUserCommand?
    private var pluginWait: Task<Void, Never>?
    private struct ApplySequence {
        let template: String
        var files: ArraySlice<URL>
        var executingFile: URL?
        let onProcessed: (URL) -> Void
    }
    private struct MenuSequence {
        let id = UUID()
        let context: UserCommandContext
        let title: String
        var remaining: ArraySlice<String>
        var directory: URL
        var previousDirectory: URL?
        var hasTerminalOutput = false
        var variables: [String: String] = [:]
        var application: ApplySequence?
    }
    private var menuSequence: MenuSequence?
    private let persistentMode = NSButton(checkboxWithTitle: L10n.text("Сохранять состояние shell"), target: nil, action: nil)
    private lazy var panelToShell = button(L10n.text("Папка панели → shell"), #selector(usePanelDirectory))
    private lazy var shellToPanel = button(L10n.text("Папка shell → панель"), #selector(useShellDirectory))
    private var sessionID = UUID()
    private var screen = TerminalScreen(columns: 100, rows: 30)
    private var history = CommandHistory()
    private var historyPosition = -1
    private var historyDraft = ""
    private var historyPrefix: String?
    private var historyPrefixIndex = 0
    private var suppressFileHistoryPath: String?
    private var separateTerminals: [SeparateCommandTerminal] = []
    private var previousDirectory: URL?
    private var lastDirectory: URL?
    private var configWindow: UserCommandsWindow?
    private var renderScheduled = false
    private var columns = 100
    private var rows = 30
    private var completionGeneration = 0
    private var completionWork: DispatchWorkItem?
    private let completionQueue = DispatchQueue(label: "FarForMac.command-completion", qos: .userInitiated)
    private let completionList = ShellCompletionList()
    private var completionSettings = ShellCompletionSettings()
    private var promptFormat = "$p$g"
    private var customPromptEnabled = false
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
        if let data = AppPreferences.defaults.data(forKey: "command.completion"), data.count <= 4096,
           let settings = try? JSONDecoder().decode(ShellCompletionSettings.self, from: data) { completionSettings = settings }
        if let format = AppPreferences.defaults.string(forKey: "command.prompt"), format.utf8.count <= 4096 { promptFormat = format }
        customPromptEnabled = AppPreferences.defaults.bool(forKey: "command.customPrompt")
        completionList.onChoose = { [weak self] command in self?.setCommand(command) }
        if loadHistory {
            do { history = try CommandHistory.load(from: AppRuntime.historyURL) }
            catch { historyWritable = false; report("История не загружена; исходный файл сохранён: \(error.localizedDescription)") }
        } else { historyWritable = false }
        input.placeholderString = "Команда в активной папке · Enter — выполнить · Tab — путь"
        input.setAccessibilityLabel("Командная строка")
        input.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        input.delegate = self; input.target = self; input.action = #selector(runInput)
        directoryLabel.maximumNumberOfLines = 1
        directoryLabel.lineBreakMode = .byTruncatingMiddle
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
        terminalText.isRichText = true; terminalText.isHorizontallyResizable = false
        terminalText.isVerticallyResizable = true
        terminalText.textContainerInset = NSSize(width: 1, height: 4)
        terminalText.textContainer?.widthTracksTextView = false
        terminalText.textContainer?.containerSize = NSSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude)
        terminalText.autoresizingMask = [.width]
        terminalText.setAccessibilityLabel(L10n.text("Вывод терминала"))
        terminalText.onInput = { [weak self] data in self?.send(data) }
        terminalText.onReport = { [weak self] data in self?.sendTerminalReport(data) }
        terminalText.onToggle = { [weak self] in self?.togglePanels() }
        terminalText.onCompositionEnd = { [weak self] in self?.scheduleTerminalRender() }
        terminalScroll.documentView = terminalText
        terminalScroll.hasVerticalScroller = true
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
        if lastDirectory != url {
            completionGeneration += 1
            completionWork?.cancel()
            completionList.dismiss()
            previousDirectory = lastDirectory
            lastDirectory = url
        }
        input.placeholderString = L10n.text(persistentMode.state == .on ? "Команда в папке shell · Enter — выполнить · Tab — путь" : "Команда в активной папке · Enter — выполнить · Tab — путь")
        refreshPrompt()
        if record { recordActivity(.folder, value: url.path) }
    }
    func refreshPrompt() {
        let directory = commandDirectory
        let prompt = ShellPrompt.render(customPromptEnabled ? promptFormat : "$p$g", directory: directory,
            environment: customPromptEnabled ? commandState.environment : [:], stackDepth: commandState.directoryStack.count,
            networkPath: promptNetworkPath?(), isAdministrator: geteuid() == 0,
            administratorLabel: L10n.text("Администратор"))
        let font = NSFont.monospacedSystemFont(ofSize: UIPreferences.fontSize(11), weight: .regular)
        let availableWidth = commandBar?.bounds.width ?? 0
        let cellWidth = max(1, ("M" as NSString).size(withAttributes: [.font: font]).width)
        let columns = availableWidth > 0 ? max(1, Int(availableWidth / cellWidth)) : 100
        let text = NSMutableAttributedString(string: "")
        func color(_ value: TerminalColor?) -> NSColor? {
            guard let (red, green, blue) = value?.rgbComponents else { return nil }
            return NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        }
        for segment in prompt.fitted(to: columns) {
            let style = segment.style, names = style.styles
            var traits: NSFontTraitMask = []
            if names.contains("bold") { traits.insert(.boldFontMask) }
            if names.contains("italic") { traits.insert(.italicFontMask) }
            var foreground = color(style.foreground) ?? Palette.muted
            var background = color(style.background)
            if names.contains("inverse") { (foreground, background) = (background ?? Palette.background, foreground) }
            if names.contains("invisible") { foreground = background ?? Palette.background }
            if names.contains("faint") { foreground = foreground.blended(withFraction: 0.5, of: background ?? Palette.background) ?? foreground }
            var attributes: [NSAttributedString.Key: Any] = [.font: traits.isEmpty ? font : NSFontManager.shared.convert(font, toHaveTrait: traits),
                                                           .foregroundColor: foreground]
            if let background { attributes[.backgroundColor] = background }
            if names.contains("strikeout") { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            let underline: NSUnderlineStyle
            if names.contains("underline_double") { underline = .double }
            else if names.contains("underline_dot") { underline = [.single, .patternDot] }
            else if names.contains("underline_dash") { underline = [.single, .patternDash] }
            else if names.contains("underline") || names.contains("underline_curly") { underline = .single }
            else { underline = [] }
            if !underline.isEmpty { attributes[.underlineStyle] = underline.rawValue }
            if let tint = color(style.underlineColor) { attributes[.underlineColor] = tint }
            text.append(NSAttributedString(string: segment.text, attributes: attributes))
        }
        let detail = persistentMode.state == .on ? L10n.text("Папка панели синхронизируется кнопками") : L10n.text("каждая команда — отдельный shell; cd меняет панель")
        if !customPromptEnabled { text.append(NSAttributedString(string: "  ·  " + detail, attributes: [.font: font, .foregroundColor: Palette.muted])) }
        directoryLabel.attributedStringValue = text
    }

    func configureCommandLine() {
        let prompt = NSTextField(string: promptFormat)
        prompt.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        prompt.setAccessibilityLabel("Формат приглашения")
        prompt.widthAnchor.constraint(equalToConstant: 440).isActive = true
        let enabled = NSButton(checkboxWithTitle: "Свой формат приглашения", target: nil, action: nil)
        enabled.state = customPromptEnabled ? .on : .off
        let automatic = NSButton(checkboxWithTitle: "Дополнять автоматически", target: nil, action: nil)
        automatic.state = completionSettings.automatic ? .on : .off
        let stack = NSStackView(views: [automatic, enabled, prompt,
            NSTextField(labelWithString: "$P — путь · $W — папка · $T — время · $+ — стек · $#nn — ширина")])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 460, height: 116)
        let alert = NSAlert()
        alert.messageText = "Настройки командной строки"
        alert.accessoryView = stack
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard prompt.stringValue.utf8.count <= 4096 else { report("Формат приглашения превышает 4 КиБ."); return }
        customPromptEnabled = enabled.state == .on
        promptFormat = prompt.stringValue
        completionSettings.automatic = automatic.state == .on
        saveCompletionSettings()
        AppPreferences.defaults.set(customPromptEnabled, forKey: "command.customPrompt")
        AppPreferences.defaults.set(promptFormat, forKey: "command.prompt")
        refreshPrompt()
    }

    func configureAutoCompletion() {
        let list = NSButton(checkboxWithTitle: "Показывать список", target: nil, action: nil)
        let modal = NSButton(checkboxWithTitle: "Модальный список по Ctrl+Пробел", target: nil, action: nil)
        let append = NSButton(checkboxWithTitle: "Добавлять первый вариант", target: nil, action: nil)
        for (button, value) in [(list, completionSettings.showList), (modal, completionSettings.modalList), (append, completionSettings.appendFirst)] {
            button.state = value ? .on : .off
        }
        let modes: [ShellCompletionMode] = [.automatic, .manualOnly, .disabled]
        let popups = ShellCompletionSource.allCases.map { source in
            let popup = NSPopUpButton()
            popup.addItems(withTitles: ["Автоматически и вручную", "Только вручную", "Выключено"])
            popup.selectItem(at: modes.firstIndex(of: completionSettings.sources[source] ?? .automatic) ?? 0)
            popup.setAccessibilityLabel(ShellCompletionList.title(source))
            return popup
        }
        let rows: [[NSView]] = zip(ShellCompletionSource.allCases, popups).map {
            [NSTextField(labelWithString: ShellCompletionList.title($0)), $1]
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 7
        let stack = NSStackView(views: [list, modal, append, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 430, height: 235)
        let alert = NSAlert()
        alert.messageText = "Настройки автодополнения"
        alert.accessoryView = stack
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        completionSettings.showList = list.state == .on
        completionSettings.modalList = modal.state == .on
        completionSettings.appendFirst = append.state == .on
        for (source, popup) in zip(ShellCompletionSource.allCases, popups) {
            completionSettings.sources[source] = modes[max(0, popup.indexOfSelectedItem)]
        }
        saveCompletionSettings()
    }

    private func saveCompletionSettings() {
        AppPreferences.defaults.set(try? JSONEncoder().encode(completionSettings), forKey: "command.completion")
    }

    func recordActivity(_ kind: ActivityHistoryKind, value: String, directory: String? = nil) {
        guard (kind != .view && kind != .edit) || suppressFileHistoryPath != value else { return }
        do { try history.record(kind: kind, value: value, directory: directory); saveHistory() }
        catch { report("История: \(error.localizedDescription)") }
    }
    func applyInterfacePreferences() {
        updateDirectory(); resizeTerminal()
        TerminalRenderer.applyHostColors(to: &screen)
        renderTerminal()
    }
    func focusCommand() { input.window?.makeFirstResponder(input) }
    func focusTerminal() { terminalText.window?.makeFirstResponder(terminalText); resizeTerminal() }
    @objc private func panels() { togglePanels() }
    @objc private func runInput() {
        if completionList.chooseSelected() { return }
        let command = input.stringValue
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if execute(command, directory: context().activeDirectory, recordHistory: preparedDraft?.isEphemeral != true) {
            if pluginWait != nil { preparedPlugin = preparedDraft }
            else if isRunning && (integration == nil || !shellReady) { preparedRunning = preparedDraft }
            else { preparedDraft?.cleanup() }
            preparedDraft = nil
            clearCommand(focus: false)
        }
    }
    @discardableResult
    func execute(_ command: String, directory: URL, recordHistory: Bool = true, menuLine: Bool = false) -> Bool {
        guard !navigatingInternalCommand, pluginWait == nil else { report("Выполняется предыдущая команда."); return false }
        guard menuLine || menuSequence == nil else { report("Выполняется последовательность команд меню."); return false }
        guard !isRunning || (persistentMode.state == .on && integration != nil && shellReady) else {
            report(L10n.text("Shell занят. Завершите ввод или программу в терминале."))
            showTerminal()
            return false
        }

        do {
            let previous = menuLine ? menuSequence?.previousDirectory : previousDirectory
            let evaluationDirectory = menuLine ? directory : (shellDirectory ?? directory)
            let dispatch = try commandState.dispatch(command, currentDirectory: evaluationDirectory, previousDirectory: previous)
            let statusDirectory = shellDirectory?.path ?? directory.path
            switch dispatch.action {
            case .shell(let command):
                try runShellCommand(command, directory: directory, echo: dispatch.echo, menuLine: menuLine)
            case .plugin(let prefix, let arguments):
                if executePluginCommand?(prefix, arguments, evaluationDirectory) == true {
                    try awaitPluginCompletion(menuLine: menuLine)
                } else {
                    try runShellCommand(dispatch.command, directory: directory, echo: dispatch.echo, menuLine: menuLine)
                }
            case .far(let command):
                guard executeFarCommand?(command) == true else {
                    throw UserCommandError("Эта команда far: недоступна в текущем контексте.")
                }
                if menuLine { scheduleNextMenuLine() }
            case .directory(let destination, let closeProvider, let stack):
                try changeInternalDirectory(to: destination, from: evaluationDirectory, closeProvider: closeProvider,
                                            stack: stack, menuLine: menuLine)
            case .skip:
                if try !applyEnvironmentToPersistentShell(), menuLine { scheduleNextMenuLine() }
            case .output(let output):
                showTerminal()
                let safe = String(output.unicodeScalars.map { scalar in
                    if scalar == "\n" { return "\r\n" }
                    if scalar == "\t" { return "\t" }
                    return CharacterSet.controlCharacters.contains(scalar) ? "�" : String(scalar)
                }.joined())
                receive(Data(safe.utf8))
                if menuLine { menuSequence?.hasTerminalOutput = true; scheduleNextMenuLine() }
            case .clearScreen:
                showTerminal()
                receive(Data("\u{1b}[2J\u{1b}[3J\u{1b}[H".utf8))
                if menuLine { menuSequence?.hasTerminalOutput = true; scheduleNextMenuLine() }
            case .title(let title):
                if let setCommandTitle { setCommandTitle(title) }
                else { input.window?.title = title ?? "FarForMac" }
                if menuLine { scheduleNextMenuLine() }
            case .exit(let status):
                if let exitFromCommand {
                    if menuLine { finishMenuSequence() }
                    exitFromCommand(status)
                } else {
                    try runShellCommand(dispatch.command, directory: directory, echo: dispatch.echo, menuLine: menuLine)
                }
            }
            if recordHistory { recordActivity(.command, value: command, directory: statusDirectory) }
            refreshPrompt()
            return true
        } catch {
            pendingCommand = nil
            report(error.localizedDescription)
            return false
        }
    }

    private func awaitPluginCompletion(menuLine: Bool) throws {
        guard pluginCommandBusy?() == true else {
            if let failure = pluginCommandFailure?() { throw UserCommandError(failure) }
            if menuLine { scheduleNextMenuLine() }
            return
        }
        let sequenceID = menuSequence?.id
        pluginWait = Task { [weak self] in
            while !Task.isCancelled, self?.pluginCommandBusy?() == true {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            guard let self, !Task.isCancelled else { return }
            self.pluginWait = nil
            self.preparedPlugin?.cleanup()
            self.preparedPlugin = nil
            guard !menuLine || self.menuSequence?.id == sequenceID else { return }
            if let failure = self.pluginCommandFailure?() {
                self.report(failure)
                if menuLine { self.finishMenuSequence() }
            } else if menuLine {
                self.scheduleNextMenuLine()
            }
        }
    }

    @discardableResult
    func cancelCommandSequence() -> Bool {
        guard menuSequence != nil || pluginWait != nil else { return false }
        if pluginWait != nil || !isRunning { cancelMenuSequence() }
        else { interrupt() }
        return true
    }

    private func runShellCommand(_ command: String, directory: URL, echo: Bool, menuLine: Bool) throws {
        if persistentMode.state == .on {
            _ = try PersistentShellIntegration.submission(command, echo: echo)
            if isRunning { try submitPersistent(command, echo: echo) }
            else {
                pendingCommand = command
                pendingCommandEcho = echo
                try start(command: nil, directory: directory, echo: echo)
            }
        } else {
            try start(command: command, directory: directory, keepingOutput: menuLine && menuSequence?.hasTerminalOutput == true, echo: echo)
        }
        if menuLine { menuSequence?.hasTerminalOutput = true }
    }

    @discardableResult
    private func executePrepared(_ prepared: PreparedUserCommand, directory: URL, menuLine: Bool = false, recordHistory: Bool = true) -> Bool {
        let previousSession = sessionID
        guard execute(prepared.command, directory: directory, recordHistory: recordHistory && !prepared.isEphemeral, menuLine: menuLine) else { return false }
        if pluginWait != nil { preparedPlugin = prepared }
        else if sessionID != previousSession || (isRunning && integration != nil && !shellReady) { preparedRunning = prepared }
        else { prepared.cleanup() }
        return true
    }
    @objc func interactiveShell() {
        guard menuSequence == nil || isRunning else { return }
        showTerminal()
        if !isRunning { do { try start(command: nil, directory: context().activeDirectory) } catch { report(error.localizedDescription) } }
        focusTerminal()
    }
    private func start(command: String?, directory: URL, keepingOutput: Bool = false, echo: Bool = true) throws {
        let id = UUID(); sessionID = id
        let sequenceID = menuSequence?.id
        cancelManagedInterrupt()
        integration?.cleanup(); integration = nil; shellReady = false; shellDirectory = nil; terminalDraft = false; awaitingInitialPrompt = false
        promptActive = false; pendingPromptClears = 0; awaitingTypedCommand = false; commandPhase = .entering
        var configuration: TerminalSession.Configuration
        if persistentMode.state == .on {
            let bridge = try PersistentShellIntegration(); integration = bridge; awaitingInitialPrompt = true
            configuration = bridge.configuration(directory: directory, columns: columns, rows: rows)
        } else {
            configuration = .init(command: command, directory: directory, columns: columns, rows: rows,
                                  environmentOverrides: ["TERM": "xterm-256color", "COLORTERM": "truecolor"])
        }
        appliedEnvironmentOverrides = commandState.environmentOverrides
        appliedEnvironmentRemovals = commandState.environmentRemovals
        let integrationDirectory = integration?.directory.path
        configuration.environmentOverrides.merge(appliedEnvironmentOverrides) { _, value in value }
        for name in appliedEnvironmentRemovals { configuration.environmentOverrides.removeValue(forKey: name) }
        if let integrationDirectory { configuration.environmentOverrides["ZDOTDIR"] = integrationDirectory }
        configuration.environmentRemovals = appliedEnvironmentRemovals.subtracting(configuration.environmentOverrides.keys)
        if keepingOutput { screen.continueWithNewProcess() }
        else { screen = TerminalScreen(columns: columns, rows: rows); terminalText.string = "" }
        TerminalRenderer.applyHostColors(to: &screen)
        terminalText.updateTerminalModes(screen)
        scheduleTerminalRender()
        terminalStatus.stringValue = "PTY · " + directory.path
        if echo { terminalStatus.stringValue += " · " + (command ?? "интерактивный shell") }
        let next = TerminalSession(configuration: configuration, onOutput: { [weak self] data in
            guard let self, self.sessionID == id else { return }; self.receive(data)
        }, onExit: { [weak self] result in
            guard let self, self.sessionID == id else { return }
            self.cancelManagedInterrupt()
            self.screen.finishProcess()
            self.terminalText.hasActiveProcess = false
            self.terminalText.updateTerminalModes(self.screen)
            self.scheduleTerminalRender()
            self.input.isEnabled = true
            self.persistentMode.isEnabled = self.menuSequence == nil
            self.shellReady = false; self.awaitingInitialPrompt = false; self.pendingCommand = nil; self.shellDirectory = nil
            self.promptActive = false; self.pendingPromptClears = 0; self.awaitingTypedCommand = false; self.terminalDraft = false
            self.integration?.cleanup(); self.integration = nil
            self.preparedRunning?.cleanup(); self.preparedRunning = nil
            self.panelToShell.isEnabled = false; self.shellToPanel.isEnabled = false
            self.updateDirectory()
            let outcome = result.signal.map { "сигнал \($0)" } ?? "код \(result.code ?? -1)"
            self.terminalStatus.stringValue = "PTY завершён: \(outcome) · Ctrl+O — вернуться к панелям"
            if configuration.command != nil, result.signal == nil,
               let sequenceID, self.menuSequence?.id == sequenceID {
                self.runNextMenuLine()
            } else {
                if configuration.command == nil || self.menuSequence?.id == sequenceID { self.menuSequence = nil }
                if self.menuSequence == nil {
                    self.persistentMode.isEnabled = true
                    self.refreshPanels()
                }
            }
        })
        session = next
        do { try next.start() } catch { session = nil; integration?.cleanup(); integration = nil; throw error }
        terminalText.hasActiveProcess = true
        persistentMode.isEnabled = false
        input.isEnabled = false; showTerminal(); focusTerminal()
    }
    private func receive(_ data: Data) {
        var completedMenuLine = false
        let displayData = integration?.filterCommandEcho(data) ?? data
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
                    completedMenuLine = menuSequence != nil && pluginWait == nil && !navigatingInternalCommand
                }
                if shellReady {
                    terminalStatus.stringValue = "zsh · " + (shellDirectory?.path ?? "") + " · " + L10n.text("Код завершения") + ": \(state.exitCode ?? 0)"
                    updateDirectory()
                    if menuSequence == nil { refreshPanels() }
                    if let command = pendingCommand {
                        pendingCommand = nil
                        do { try submitPersistent(command, echo: pendingCommandEcho) }
                        catch { preparedRunning?.cleanup(); preparedRunning = nil; menuSequence = nil; report(error.localizedDescription) }
                    }
                } else if promptActive && terminalDraft {
                    terminalStatus.stringValue = L10n.text("Есть ввод в терминале · Ctrl+C — очистить строку и включить командную строку")
                }
            }
            if promptActive, managedInterrupt != nil { finishManagedInterrupt() }
        }
        screen.append(displayData)
        let responses = screen.takeResponses()
        if !responses.isEmpty { try? session?.send(responses) }
        terminalText.updateTerminalModes(screen)
        if completedMenuLine, let id = menuSequence?.id {
            if shellReady { DispatchQueue.main.async { [weak self] in
                guard let self, self.menuSequence?.id == id else { return }
                self.runNextMenuLine()
            } }
            else { menuSequence = nil }
        }
        scheduleTerminalRender()
    }
    private func sendTerminalReport(_ data: Data) {
        guard isRunning, managedInterrupt == nil else { return }
        try? session?.send(data)
    }
    private var terminalFont: NSFont { .monospacedSystemFont(ofSize: UIPreferences.fontSize(13), weight: .regular) }
    private func scheduleTerminalRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }; self.renderScheduled = false
            self.renderTerminal()
        }
    }
    private func renderTerminal() {
        guard !terminalText.hasMarkedText() else { return }
        let font = terminalFont
        let geometry = TerminalRenderer.geometry(font: font)
        let clip = terminalScroll.contentView
        let selection = terminalText.selectedRange()
        let wasAtBottom = terminalText.bounds.maxY <= clip.bounds.maxY + geometry.lineHeight
        terminalText.updateTerminalGeometry(screen, geometry: geometry)
        TerminalRenderer.update(terminalText, screen: screen, font: font)
        let length = (terminalText.string as NSString).length
        if !screen.isAlternateScreen, selection.length > 0, NSMaxRange(selection) <= length {
            terminalText.setSelectedRange(selection)
        } else {
            let cursor = NSRange(location: min(screen.cursorOffset, length), length: 0)
            terminalText.setSelectedRange(cursor)
            if screen.isAlternateScreen {
                clip.scroll(to: .zero)
                terminalScroll.reflectScrolledClipView(clip)
            } else if wasAtBottom {
                terminalText.scrollRangeToVisible(cursor)
            }
        }
    }
    private func resizeTerminal() {
        let size = terminalScroll.contentSize
        guard size.width > 40, size.height > 40 else { return }
        let geometry = TerminalRenderer.geometry(font: terminalFont)
        let newColumns = max(10, min(400, Int((size.width - terminalText.horizontalTextInset) / geometry.cellWidth)))
        let newRows = max(3, min(200, Int((size.height - terminalText.verticalTextInset) / geometry.lineHeight)))
        guard newColumns != columns || newRows != rows else { return }
        columns = newColumns; rows = newRows; screen.resize(columns: columns, rows: rows)
        scheduleTerminalRender()
        if isRunning { do { try session?.resize(columns: columns, rows: rows) } catch { report(error.localizedDescription) } }
    }
    private func send(_ data: Data) {
        let interruptKey = data == Data([3])
        if interruptKey { cancelMenuSequence() }
        guard isRunning else { return }
        if integration != nil {
            guard !awaitingInitialPrompt else { if !interruptKey { NSSound.beep() }; return }
            if interruptKey {
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
    private func environmentUpdatesForPersistentShell() throws -> [String] {
        var updates: [String] = []
        for name in commandState.environmentRemovals.subtracting(appliedEnvironmentRemovals).sorted()
            where InternalCommandState.validShellName(name) {
            updates.append("builtin unset -- " + name)
        }
        for (name, value) in commandState.environmentOverrides.sorted(by: { $0.key < $1.key })
            where appliedEnvironmentOverrides[name] != value && InternalCommandState.validShellName(name) {
            updates.append("builtin export " + name + "=" + (try ShellCommand.quoteArgument(value)))
        }
        return updates
    }

    private func applyEnvironmentToPersistentShell() throws -> Bool {
        guard isRunning, integration != nil, try !environmentUpdatesForPersistentShell().isEmpty else { return false }
        try submitPersistent("", echo: false)
        return true
    }

    private func submitPersistent(_ command: String, echo: Bool = true) throws {
        guard shellReady else { throw TerminalSession.SessionError.notRunning }
        var lines = try environmentUpdatesForPersistentShell()
        if !command.isEmpty { lines.append(command) }
        try session?.sendToForegroundShell(PersistentShellIntegration.submission(lines.joined(separator: "; "), echo: echo))
        if !echo { integration?.suppressNextCommandEcho() }
        appliedEnvironmentOverrides = commandState.environmentOverrides
        appliedEnvironmentRemovals = commandState.environmentRemovals
        promptActive = false; awaitingTypedCommand = true; commandPhase = .entering
        shellReady = false; input.isEnabled = false; panelToShell.isEnabled = false; shellToPanel.isEnabled = false
        showTerminal(); focusTerminal()
    }
    @objc private func changeShellMode() {
        guard !isRunning else { persistentMode.state = integration == nil ? .off : .on; return }
        updateDirectory()
    }
    @objc private func usePanelDirectory() {
        guard shellReady, menuSequence == nil else { return }
        do { try submitPersistent("builtin cd -- " + ShellCommand.quoteArgument(context().activeDirectory.path)) }
        catch { report(error.localizedDescription) }
    }
    @objc private func useShellDirectory() {
        guard shellReady, menuSequence == nil, let directory = shellDirectory else { return }
        navigate(directory)
    }
    @objc private func interrupt() {
        cancelMenuSequence()
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
    @objc private func stop() { cancelMenuSequence(); session?.stop() }
    func stopForExit() {
        if pluginWait != nil { cancelPluginCommand?() }
        pluginWait?.cancel()
        pluginWait = nil
        preparedPlugin?.cleanup()
        preparedPlugin = nil
        completionGeneration += 1
        completionWork?.cancel()
        completionList.dismiss()
        cancelManagedInterrupt()
        configWindow?.finalizeClose()
        for terminal in separateTerminals { terminal.workspace?.stopForExit() }
        session?.forceStop(); integration?.cleanup(); pendingCommand = nil; menuSequence = nil
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
        case #selector(NSResponder.moveUp(_:)):
            if completionList.isShown { completionList.move(backward: true) }
            else { previousCommand(backward: true) }
            return true
        case #selector(NSResponder.moveDown(_:)):
            if completionList.isShown { completionList.move(backward: false) }
            else { previousCommand(backward: false) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if completionList.isShown { completionList.dismiss() }
            else { clearCommand() }
            return true
        default: return false
        }
    }
    func previousCommand(backward: Bool) {
        let commands = history.filtered(kind: .command)
        if historyPosition == -1 { historyDraft = input.stringValue }
        let next = max(-1, min(commands.count - 1, historyPosition + (backward ? 1 : -1)))
        setCommand(next < 0 ? historyDraft : commands[next].value)
        historyPosition = next
    }

    func clearCommand(focus: Bool = true) {
        setCommand("", focus: focus)
    }

    func copyCommandOrPanelSelection(to pasteboard: NSPasteboard = .general) {
        let command = input.stringValue as NSString
        let value: String
        if command.length == 0 {
            let ctx = context()
            let files = ctx.markedFiles.isEmpty ? ctx.currentFile.map { [$0] } ?? [] : ctx.markedFiles
            guard !files.isEmpty else { return }
            value = files.map(\.lastPathComponent).joined(separator: "\n")
        } else if let selected = input.currentEditor()?.selectedRange, selected.length > 0, NSMaxRange(selected) <= command.length {
            value = command.substring(with: selected)
        } else {
            value = String(command)
        }
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    @discardableResult
    func runSeparateInput() -> Bool {
        let command = input.stringValue
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if runSeparateCommand(command, prepared: preparedDraft) {
            preparedDraft = nil
            clearCommand(focus: false)
        }
        return true
    }

    @discardableResult
    func completeHistoryPrefix() -> Bool {
        let command = input.stringValue
        if let editor = input.currentEditor(), NSMaxRange(editor.selectedRange) != command.utf16.count { return false }
        let prefix = historyPrefix ?? command
        let candidates = history.completions(for: prefix)
        guard !candidates.isEmpty else { return true }
        let index = historyPrefixIndex % candidates.count
        let choice = candidates[index]
        setCommand(choice)
        historyPrefix = prefix
        historyPrefixIndex = index + 1
        let start = min(prefix.utf16.count, choice.utf16.count)
        input.currentEditor()?.selectedRange = NSRange(location: start, length: choice.utf16.count - start)
        return true
    }

    func insertPanelValue(_ insertion: ShellPanelInsertion) {
        do {
            guard let value = try ShellCommand.panelInsertion(insertion, context: context()) else { return }
            let current = input.stringValue as NSString
            let selection = input.currentEditor()?.selectedRange ?? NSRange(location: current.length, length: 0)
            guard NSMaxRange(selection) <= current.length else { return }
            setCommand(current.replacingCharacters(in: selection, with: value))
            input.currentEditor()?.selectedRange = NSRange(location: selection.location + value.utf16.count, length: 0)
            historyPosition = -1
        } catch { report(error.localizedDescription) }
    }

    func completePath() {
        if input.currentEditor() == nil { focusCommand() }
        requestCompletion(manual: true)
    }

    private var macrosSuppressCompletion: Bool {
        FarLuaWorkspace.shared.isRecording || FarLuaWorkspace.shared.isRunning ||
            CommandWorkspace.shared.macros.isRecording || CommandWorkspace.shared.macros.isPlaying
    }

    private func requestCompletion(manual: Bool) {
        guard input.isEnabled, manual || (completionSettings.automatic && !macrosSuppressCompletion) else { return }
        let editor = input.currentEditor() as? NSTextView
        let value = editor?.string ?? input.stringValue
        guard manual || !value.isEmpty else { completionList.dismiss(); return }
        if let editor {
            guard !editor.hasMarkedText(), NSMaxRange(editor.selectedRange()) == value.utf16.count else { return }
        }
        completionWork?.cancel()
        let directory = commandDirectory, settings = completionSettings
        let entries = history.completions(for: value), environment = commandState.environment
        completionGeneration += 1
        let token = completionGeneration
        let work = DispatchWorkItem { [weak self] in
            let result = Result {
                try ShellCommand.completeLine(value, currentDirectory: directory, history: entries,
                    environment: environment, settings: settings, manual: manual)
            }
            DispatchQueue.main.async {
                guard let self, self.completionGeneration == token,
                      ((self.input.currentEditor() as? NSTextView)?.string ?? self.input.stringValue) == value,
                      self.commandDirectory == directory, manual || !self.macrosSuppressCompletion else { return }
                self.completionWork = nil
                do { self.showCompletion(try result.get(), original: value, manual: manual) }
                catch { if manual { self.report(error.localizedDescription) } }
            }
        }
        completionWork = work
        completionQueue.asyncAfter(deadline: .now() + (manual ? 0 : 0.16), execute: work)
    }

    private func showCompletion(_ completion: ShellCompletion, original: String, manual: Bool) {
        guard let first = completion.candidates.first else {
            completionList.dismiss()
            if manual { report(completion.isTruncated ? "Достигнут предел поиска дополнений." : "Нет дополнений команды.") }
            return
        }
        if manual, completion.candidates.count == 1, !completion.isTruncated {
            setCommand(first.command)
            return
        }
        if completionSettings.appendFirst,
           first.command.range(of: original, options: [.anchored, .caseInsensitive]) != nil {
            setCommand(first.command)
            let start = min(original.utf16.count, first.command.utf16.count)
            input.currentEditor()?.selectedRange = NSRange(location: start, length: first.command.utf16.count - start)
        }
        guard completionSettings.showList else { return }
        if manual, completionSettings.modalList {
            let menu = PanelListMenu(title: "Дополнить команду", hint: completion.isTruncated
                ? "Показана ограниченная часть совпадений · Enter — вставить" : "Enter — вставить · Esc — отменить")
            menu.macroArea = "ShellAutoCompletion"
            menu.replaceRows(completion.candidates.map {
                .init(title: ShellCompletionList.title($0.source) + " · " + $0.command.replacingOccurrences(of: "\n", with: "↵"))
            })
            var selected: String?
            menu.onActivate = { [weak menu] row in selected = completion.candidates[row].command; menu?.dismiss() }
            menu.run(relativeTo: input.window)
            if let selected { setCommand(selected) }
        } else {
            completionList.show(completion.candidates, at: input, selectFirst: manual)
            if manual, completion.isTruncated { report("Показана ограниченная часть совпадений.") }
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
            if action == .shiftedOpen {
                if runSeparateCommand(entry.value) { clearCommand(focus: false) }
            } else { runInput() }
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

    private func runSeparateCommand(_ command: String, prepared: PreparedUserCommand? = nil) -> Bool {
        guard menuSequence == nil, pluginWait == nil, !navigatingInternalCommand else {
            report("Выполняется предыдущая последовательность команд.")
            return false
        }
        let current = context(), directory = current.activeDirectory
        let conditioned: String
        do {
            guard let value = try commandState.conditionallyExecutable(command, currentDirectory: directory) else {
                prepared?.cleanup()
                if prepared?.isEphemeral != true { recordActivity(.command, value: command, directory: directory.path) }
                return true
            }
            conditioned = value
        } catch { report(error.localizedDescription); return false }
        let trimmed = conditioned.drop(while: \.isWhitespace)
        let echo = !trimmed.hasPrefix("@")
        let executable = echo ? conditioned : String(trimmed.drop(while: { $0 == "@" }).drop(while: \.isWhitespace))
        let terminal = SeparateCommandTerminal()
        let shell = ShellWorkspace(context: { current }, navigate: { _ in }, openFile: { _, _ in },
            showTerminal: { [weak terminal] in terminal?.showWindow(nil) },
            togglePanels: { [weak self] in self?.input.window?.makeKeyAndOrderFront(nil) },
            refreshPanels: refreshPanels, report: report, loadHistory: false)
        terminal.workspace = shell
        terminal.window?.contentView = shell.terminalView
        terminal.onClose = { [weak self, weak terminal] in self?.separateTerminals.removeAll { $0 === terminal } }
        do {
            shell.commandState = commandState
            try shell.start(command: executable, directory: directory, echo: echo)
            shell.preparedRunning = prepared
            separateTerminals.append(terminal)
            if prepared?.isEphemeral != true { recordActivity(.command, value: command, directory: directory.path) }
            return true
        } catch { report(error.localizedDescription); return false }
    }
    private func saveHistory() {
        guard historyWritable else { return }
        let snapshot = history
        let historyURL = AppRuntime.historyURL
        historyQueue.async { [weak self] in
            do { try snapshot.save(to: historyURL) } catch { let message = error.localizedDescription; DispatchQueue.main.async { self?.report(message) } }
        }
    }
    func controlTextDidChange(_ notification: Notification) {
        historyPosition = -1
        historyPrefix = nil; historyPrefixIndex = 0
        requestCompletion(manual: false)
    }
    private func setCommand(_ value: String, prepared: PreparedUserCommand? = nil, focus: Bool = true) {
        completionGeneration += 1
        completionWork?.cancel()
        completionList.dismiss()
        historyPrefix = nil; historyPrefixIndex = 0
        if let prepared { preparedDraft?.cleanup(); preparedDraft = prepared }
        else if let draft = preparedDraft, !draft.listFiles.values.contains(where: { value.contains($0.path) }) {
            draft.cleanup(); preparedDraft = nil
        }
        input.stringValue = value; historyPosition = -1
        if focus { focusCommand() }
    }
    func showUserMenu(store: UserCommandStore? = nil, smokeKey: PanelListMenu.SmokeKey? = nil) {
        do {
            let store = store ?? AppRuntime.commandStore
            let ctx = context()
            let menu = try UserMenuOverlay(store: store, context: ctx)
            menu.onHelp = showUserMenuHelp
            menu.onPlugins = showUserMenuPlugins
            switch menu.run(relativeTo: input.window, smokeKey: smokeKey) {
            case .command(let entry, let title):
                guard let template = entry.command else { return }
                if entry.farSyntax == true { startMenuSequence(template, title: title, context: ctx) }
                else if let prepared = try prepareUserCommand(template, title: title, context: ctx) {
                    executePrepared(prepared, directory: ctx.activeDirectory)
                }
            case .editFile(let loaded):
                if loaded.isFarMenu { showCommandConfiguration(store, farMenu: loaded) }
                else { showCommandConfiguration(UserCommandStore(globalURL: loaded.source)) }
            case nil: break
            }
        } catch { report(error.localizedDescription) }
    }
    private func checkMenuDirectory(_ directory: URL) -> Bool {
        guard persistentMode.state != .on || !isRunning || shellDirectory?.standardizedFileURL == directory.standardizedFileURL else {
            report(L10n.text("Для меню и ассоциаций сначала нажмите «Папка панели → shell»: команды относятся к файлам активной панели."))
            return false
        }
        return true
    }
    func applyCommand(onBegin: () -> Void, onProcessed: @escaping (URL) -> Void) {
        guard menuSequence == nil, pluginWait == nil else { report("Выполняется предыдущая последовательность команд."); return }
        let ctx = context()
        let files = ctx.markedFiles.isEmpty ? ctx.currentFile.map { [$0] } ?? [] : ctx.markedFiles
        guard !files.isEmpty, files.allSatisfy(\.isFileURL), checkMenuDirectory(ctx.activeDirectory) else { return }
        let key = "ApplyCmd"
        let previous = history.parameterHistory.values(for: key)
        let field = NSComboBox(frame: NSRect(x: 0, y: 0, width: 470, height: 26))
        field.addItems(withObjectValues: previous)
        field.stringValue = previous.first ?? ""
        field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        field.setAccessibilityLabel("Команда для выбранных файлов")
        let dialog = NSAlert()
        dialog.messageText = "Применить команду"
        dialog.informativeText = "Введите команду для выбранных файлов."
        dialog.accessoryView = field
        dialog.addButton(withTitle: "Выполнить")
        dialog.addButton(withTitle: "Отмена")
        dialog.window.initialFirstResponder = field
        guard dialog.runModal() == .alertFirstButtonReturn else { return }
        let template = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !template.isEmpty, template.utf8.count <= 16_384,
              !template.utf8.contains(0), !template.contains(where: \.isNewline) else {
            report("Команда для применения должна быть одной непустой строкой до 16 КиБ.")
            return
        }
        history.parameterHistory.record(template, for: key)
        saveHistory()
        onBegin()
        startApplySequence(template, files: files, context: ctx, onProcessed: onProcessed)
    }

    private func startApplySequence(_ template: String, files: [URL], context: UserCommandContext,
                                    onProcessed: @escaping (URL) -> Void) {
        let application = ApplySequence(template: template, files: files[...], onProcessed: onProcessed)
        menuSequence = MenuSequence(context: context, title: "Применить команду", remaining: [],
            directory: context.activeDirectory, previousDirectory: previousDirectory, application: application)
        persistentMode.isEnabled = false
        runNextMenuLine()
    }

    private func startMenuSequence(_ block: String, title: String, context: UserCommandContext) {
        guard menuSequence == nil else { report("Выполняется последовательность команд меню."); return }
        guard checkMenuDirectory(context.activeDirectory) else { return }
        menuSequence = MenuSequence(context: context, title: title, remaining: FarMenuImporter.commandLines(in: block)[...],
                                    directory: context.activeDirectory, previousDirectory: previousDirectory)
        persistentMode.isEnabled = false
        runNextMenuLine()
    }
    private func changeInternalDirectory(to destination: URL, from directory: URL, closeProvider: Bool,
                                         stack: InternalDirectoryStackChange?, menuLine: Bool) throws {
        let sequenceID = menuSequence?.id
        let isLeft = menuSequence?.context.activePanelIsLeft ?? context().activePanelIsLeft
        let completion: (Bool) -> Void = { [weak self] changed in
            DispatchQueue.main.async {
                guard let self else { return }
                self.navigatingInternalCommand = false
                guard !menuLine || self.menuSequence?.id == sequenceID else { return }
                if changed {
                    if let stack { self.commandState.commit(stack) }
                    self.refreshPrompt()
                    if menuLine {
                        self.menuSequence?.previousDirectory = directory
                        self.menuSequence?.directory = destination
                    }
                }
                do {
                    if self.isRunning, self.integration != nil {
                        if changed && menuLine {
                            try self.submitPersistent("builtin cd -- " + ShellCommand.quoteArgument(destination.path))
                            return
                        }
                        if try self.applyEnvironmentToPersistentShell() { return }
                    }
                    if menuLine { self.scheduleNextMenuLine() }
                } catch {
                    self.report(error.localizedDescription)
                    if menuLine { self.finishMenuSequence() }
                }
            }
        }
        if let navigateInternalDirectory {
            navigatingInternalCommand = true
            navigateInternalDirectory(destination, isLeft, closeProvider, completion)
        } else if let navigateMenuDirectory {
            navigatingInternalCommand = true
            navigateMenuDirectory(destination, isLeft, completion)
        } else {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw UserCommandError("Не удалось открыть папку \(destination.path).")
            }
            navigate(destination)
            if let stack { commandState.commit(stack) }
            if menuLine {
                menuSequence?.previousDirectory = directory
                menuSequence?.directory = destination
                scheduleNextMenuLine()
            }
        }
    }

    private func scheduleNextMenuLine() {
        guard let id = menuSequence?.id else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.menuSequence?.id == id else { return }
            self.runNextMenuLine()
        }
    }
    private func cancelMenuSequence() {
        if pluginWait != nil { cancelPluginCommand?() }
        guard menuSequence != nil else { return }
        menuSequence = nil
        if !isRunning { persistentMode.isEnabled = true }
        if awaitingInitialPrompt {
            pendingCommand = nil
            preparedRunning?.cleanup(); preparedRunning = nil
        }
    }
    private func finishMenuSequence() {
        let refresh = menuSequence?.hasTerminalOutput == true
        menuSequence = nil
        if !isRunning { persistentMode.isEnabled = true }
        if refresh { refreshPanels() }
    }
    private func runNextMenuLine() {
        guard var sequence = menuSequence else { return }
        let line: String
        let context: UserCommandContext
        if var application = sequence.application {
            if let completed = application.executingFile { application.onProcessed(completed) }
            guard menuSequence?.id == sequence.id else { return }
            guard let file = application.files.popFirst() else { finishMenuSequence(); return }
            let usesMarks = ["!&", "!@", "!$"].contains { application.template.contains($0) }
            let remainingMarks = usesMarks && !sequence.context.markedFiles.isEmpty ? [file] + application.files : nil
            context = sequence.context.replacingCurrentFile(file, directory: sequence.directory, markedFiles: remainingMarks)
            line = application.template
            application.executingFile = file
            sequence.application = application
        } else {
            guard let next = sequence.remaining.popFirst() else { finishMenuSequence(); return }
            line = next
            context = sequence.context.replacingCurrentFile(sequence.context.currentFile, directory: sequence.directory)
        }
        menuSequence = sequence
        do {
            let template = try FarMenuMetasymbols.command(line, context: context, variables: sequence.variables, variablesArePrivate: true)
            let prepared = try prepareUserCommand(template, title: sequence.title, context: context, checkDirectory: false)
            guard menuSequence?.id == sequence.id else { return }
            if let prepared, executePrepared(prepared, directory: sequence.directory, menuLine: true, recordHistory: sequence.application == nil) {
                return
            }
        } catch {
            report(error.localizedDescription)
        }
        finishMenuSequence()
    }
    private func prepareUserCommand(_ template: String, title: String, context ctx: UserCommandContext,
                                    checkDirectory: Bool = true) throws -> PreparedUserCommand? {
        guard !checkDirectory || checkMenuDirectory(ctx.activeDirectory) else { return nil }
        let parameters = try UserCommandExpander.inputs(in: template)
        var parameterHistory = history.parameterHistory
        guard let values = UserCommandParameterForm.collect(parameters, title: title, history: &parameterHistory) else { return nil }
        let prepared = try UserCommandExpander.prepare(template, context: ctx, inputValues: values)
        if parameterHistory != history.parameterHistory {
            history.parameterHistory = parameterHistory
            saveHistory()
        }
        if !checkDirectory, menuSequence?.application == nil {
            for parameter in parameters {
                guard let name = parameter.variableName, let value = values[parameter.identifier],
                      menuSequence?.variables.keys.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) != true else { continue }
                menuSequence?.variables[name] = value
            }
        }
        return prepared
    }
    @objc func configureCommands() { showCommandConfiguration(AppRuntime.commandStore) }
    private func showCommandConfiguration(_ store: UserCommandStore, farMenu: LoadedUserMenu? = nil) {
        if let configWindow, configWindow.window?.isVisible == true {
            if configWindow.sourceURL == (farMenu?.source ?? store.globalURL) { configWindow.showWindow(nil); return }
            configWindow.window?.performClose(nil)
            if configWindow.window?.isVisible == true { return }
        }
        configWindow = UserCommandsWindow(store: store, farMenu: farMenu); configWindow?.showWindow(nil)
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
        let canceledMarker = root.appendingPathComponent("commandx-canceled-" + UUID().uuidString)
        let canceledBlock = "printf canceled > " + (try ShellCommand.quoteArgument(canceledMarker.path))
        workspace.startMenuSequence(canceledBlock, title: "Cancel before prompt", context: workspace.context())
        guard workspace.awaitingInitialPrompt, workspace.pendingCommand != nil else {
            throw NetworkError.io("CommandX fixture must queue its first line before the initial prompt")
        }
        workspace.send(Data([3]))
        try await wait("initial prompt after CommandX Ctrl+C") { workspace.shellReady }
        guard workspace.menuSequence == nil, !FileManager.default.fileExists(atPath: canceledMarker.path) else {
            throw NetworkError.io("Ctrl+C before the initial prompt must cancel the queued CommandX line")
        }
        guard workspace.execute("export FAR_UI_SMOKE_VALUE=retained; cd -- " + (try ShellCommand.quoteArgument(child.path)), directory: root) else { throw NetworkError.io("Could not start managed shell") }
        try await wait("prompt after initial command") { workspace.shellReady }
        guard navigation == nil, workspace.shellDirectory?.resolvingSymlinksInPath() == child.resolvingSymlinksInPath(), workspace.input.isEnabled,
              workspace.input.placeholderString == L10n.text("Команда в папке shell · Enter — выполнить · Tab — путь") else { throw NetworkError.io("Shell cwd must not move panels automatically") }
        let rejected = try workspace.prepareUserCommand("printf '%s' {name}", title: "fixture", context: workspace.context())
        guard rejected == nil else { throw NetworkError.io("Unexpected command accepted in another shell directory") }
        guard messages.count == 1 else { throw NetworkError.io("Menu command must refuse a different shell directory") }
        workspace.useShellDirectory()
        guard navigation?.resolvingSymlinksInPath() == child.resolvingSymlinksInPath() else { throw NetworkError.io("Explicit shell-to-panel navigation failed") }
        workspace.usePanelDirectory(); try await wait("prompt after panel directory sync") { workspace.shellReady }
        guard workspace.shellDirectory?.resolvingSymlinksInPath() == root.resolvingSymlinksInPath() else { throw NetworkError.io("Explicit panel-to-shell cd failed") }
        guard workspace.execute("set FAR_MANAGED_INTERNAL=retained", directory: root) else {
            throw NetworkError.io("The managed shell rejected FAR SET")
        }
        try await wait("managed FAR environment update") { workspace.shellReady }
        // Interactive zsh can pass a trailing # token to printf as an argument.
        // Use a no-op to put the marker only in the typed command's echo.
        guard workspace.execute(#"@if defined FAR_MANAGED_INTERNAL : hidden-echo-fixture; printf 'FAR_INTERNAL:%s\n' "$FAR_MANAGED_INTERNAL""#, directory: root) else {
            throw NetworkError.io("The managed shell rejected FAR conditional execution")
        }
        try await wait("managed FAR conditional") { workspace.shellReady }
        guard workspace.screen.plainText.contains("FAR_INTERNAL:retained"),
              !workspace.screen.plainText.contains("hidden-echo-fixture") else {
            throw NetworkError.io("Managed FAR command did not inherit SET or suppress its echo\n" + workspace.screen.plainText.suffix(2_000))
        }
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
        workspace.startMenuSequence(canceledBlock, title: "Cancel before prompt", context: workspace.context())
        guard workspace.awaitingInitialPrompt, workspace.pendingCommand != nil else {
            throw NetworkError.io("CommandX fixture must queue its first line in the new shell")
        }
        workspace.interrupt()
        try await wait("initial prompt after CommandX interrupt button") { workspace.shellReady }
        guard workspace.menuSequence == nil, !FileManager.default.fileExists(atPath: canceledMarker.path) else {
            throw NetworkError.io("The interrupt button must cancel the queued CommandX line before the initial prompt")
        }
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
        workspace.startMenuSequence("export FAR_MENU_SMOKE=retained\nprintf 'MENU_STATE:%s' \"$FAR_MENU_SMOKE\"", title: "Managed sequence", context: workspace.context())
        try await wait("managed CommandX sequence") { workspace.menuSequence == nil && workspace.shellReady }
        guard workspace.screen.plainText.contains("MENU_STATE:retained") else {
            throw NetworkError.io("Managed CommandX must wait for the prompt and preserve shell state between its lines")
        }
        let draft = try UserCommandExpander.prepare("cat {list0}", context: workspace.context())
        let draftURL = draft.listFiles["list0"]!
        workspace.setCommand(draft.command, prepared: draft)
        guard FileManager.default.fileExists(atPath: draftURL.path) else { throw NetworkError.io("Inserted list command lost its resources") }
        workspace.setCommand("printf replacement")
        guard !FileManager.default.fileExists(atPath: draftURL.path) else { throw NetworkError.io("Replacing an inserted command must clean unused list files") }
        return ["List files survive managed shell execution and are removed at prompt; replacing a draft releases its files", "Managed shell command bar preserves state without implicit panel navigation", "Shell directory sync is explicit and menu commands reject directory mismatch", "Partial terminal input blocks command bar and Ctrl+C restores prompt", "Rapid and repeated Ctrl+C preserve new input through job handoff, continuation and quoted Enter", "Raw programs sharing the shell group receive the Ctrl+C byte", "CommandX Ctrl+C and interrupt cancel the first queued line before the managed shell prompt", "Shell exit clears cwd and a new session starts without old variables"] + (try await runMenuSmoke(in: root))
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

        try workspace.history.record(kind: .command, value: "printf 'HISTORY_%s' SEPARATE", directory: directory.path)
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
        workspace.input.stringValue = "draft"
        workspace.previousCommand(backward: true)
        let newest = workspace.input.stringValue
        workspace.previousCommand(backward: true)
        let older = workspace.input.stringValue
        workspace.previousCommand(backward: false)
        workspace.previousCommand(backward: false)
        guard newest.contains("SEPARATE"), older.contains("ENTER"), workspace.input.stringValue == "draft" else {
            throw NetworkError.io("Command history must cycle and restore the untouched draft.")
        }
        workspace.clearCommand(focus: false)

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

        let nested = directory.appendingPathComponent("working", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let panel = PanelView(directory: directory, key: "commandx-" + UUID().uuidString)
        var directoryChanges: [Bool] = []
        workspace.refreshPanels = { panel.load() }
        workspace.navigateMenuDirectory = { url, _, completion in
            panel.navigateHistory(to: url.path, focus: false) { committed in
                directoryChanges.append(committed)
                completion(committed)
            }
        }
        let native = directory.appendingPathComponent(UserCommandStore.farMenuFilename)
        let nativeText = """
        F4: CommandX
          REM skipped !unsupported
          printf 'COMMANDX_%s' FIRST
          false
          pushd working
          cd missing
          set FAR_COMMANDX_TEST=retained
          @if defined FAR_COMMANDX_TEST printf 'COMMANDX_%s:' LAST; basename "$PWD"
          popd
        """
        // PUSHD and POPD use asynchronous panel navigation. The failed CD
        // leaves the successful destination in place for the conditional step.
        try Data(nativeText.utf8).write(to: native)
        workspace.showUserMenu(store: store, smokeKey: .init(code: 118, characters: String(UnicodeScalar(Int(NSF4FunctionKey))!), modifiers: .function))
        try await waitForOutput {
            workspace.screen.plainText.contains("COMMANDX_LAST:working") && !workspace.isRunning && workspace.menuSequence == nil
        }
        guard workspace.screen.plainText.contains("COMMANDX_FIRST") else {
            throw NetworkError.io("Native F2 lost the transcript of the first CommandX step")
        }
        guard directoryChanges == [true, false, true], panel.directory.resolvingSymlinksInPath() == directory.resolvingSymlinksInPath(),
              workspace.commandState.directoryStack.isEmpty else {
            throw NetworkError.io("CommandX must commit PUSHD, continue after failed CD and return through POPD")
        }
        workspace.showUserMenu(store: store, smokeKey: .init(code: 118, characters: String(UnicodeScalar(Int(NSF4FunctionKey))!), modifiers: [.function, .option]))
        guard workspace.configWindow?.sourceURL == native, workspace.configWindow?.window?.isVisible == true else {
            throw NetworkError.io("Alt+F4 should edit the actual source of the native F2 menu")
        }
        workspace.configWindow?.window?.performClose(nil)
        owner.makeKeyAndOrderFront(nil)

        let one = UserFileAssociation(title: "Single", mask: "*.txt", alternateView: "printf 'ASSOCIATION_%s' SINGLE")
        let two = UserFileAssociation(title: "Multiple", mask: "*.txt", alternateView: "printf 'ASSOCIATION_%s' SECOND")
        func installAssociations(_ associations: [UserFileAssociation]) throws {
            let data = try JSONEncoder().encode(UserCommandConfiguration(associations: associations))
            try store.saveGlobalText(String(decoding: data, as: UTF8.self))
        }
        try installAssociations([one])
        guard workspace.association(for: file, action: .alternateView, store: store) else {
            throw NetworkError.io("Single association was not consumed")
        }
        try await waitForOutput { workspace.screen.plainText.contains("ASSOCIATION_SINGLE") && !workspace.isRunning }
        try installAssociations([two, one])
        guard workspace.association(for: file, action: .alternateView, store: store, smokeKey: .init(code: 36)) else {
            throw NetworkError.io("Multiple matching associations did not open a choice")
        }
        try await waitForOutput { workspace.screen.plainText.contains("ASSOCIATION_SECOND") && !workspace.isRunning }

        let another = directory.appendingPathComponent("name with a space.txt")
        try Data().write(to: another)
        let files = [file, another]
        let applicationContext = UserCommandContext(currentFile: file, markedFiles: files, activeDirectory: directory, passiveDirectory: directory)
        var processed: [URL] = []
        workspace.startApplySequence(#"printf 'APPLY:%s\n' !.!.bak"#, files: files, context: applicationContext) { processed.append($0) }
        try await waitForOutput { workspace.menuSequence == nil && !workspace.isRunning }
        guard processed == files, workspace.screen.plainText.contains("APPLY:fixture.txt.bak"),
              workspace.screen.plainText.contains("APPLY:name with a space.txt.bak") else {
            throw NetworkError.io("Apply command must substitute and execute once for each file in selection order.")
        }

        let help = HlfViewerWorkspace()
        let helpFile = directory.appendingPathComponent("sample.hlf")
        try ".Language=English\n@Contents\nExample".write(to: helpFile, atomically: true, encoding: .utf8)
        workspace.executePluginCommand = { help.executePrefix($0, $1, directory: $2) }
        workspace.pluginCommandFailure = { help.lastFailure }
        workspace.startMenuSequence("hlf: sample.hlf @Missing\nprintf 'HLF_%s' SENTINEL", title: "HLF CommandX", context: applicationContext)
        let expectedHelpError = FarHelpError.missingTopic("Missing").localizedDescription
        guard help.lastFailure == expectedHelpError, workspace.menuSequence == nil, !workspace.isRunning,
              !workspace.screen.plainText.contains("HLF_SENTINEL") else {
            throw NetworkError.io("A missing HLF topic must stop CommandX before its next line.")
        }
        processed.removeAll()
        help.clearFailure()
        workspace.startApplySequence("hlf: sample.hlf @Missing", files: files, context: applicationContext) { processed.append($0) }
        guard help.lastFailure == expectedHelpError, workspace.menuSequence == nil, !workspace.isRunning, processed.isEmpty else {
            throw NetworkError.io("Apply must keep the first file marked after an HLF error.")
        }

        var busy = false, lists: [URL] = [], failure: String?
        workspace.pluginCommandBusy = { busy }
        workspace.pluginCommandFailure = { failure }
        workspace.cancelPluginCommand = { busy = false }
        workspace.executePluginCommand = { prefix, arguments, actualDirectory in
            guard prefix == "fixture", actualDirectory.path == directory.path else { return false }
            let quoted = arguments.trimmingCharacters(in: .whitespaces)
            guard quoted.hasPrefix("'"), quoted.hasSuffix("'") else { return false }
            lists.append(URL(fileURLWithPath: String(quoted.dropFirst().dropLast())))
            busy = true
            return true
        }
        processed.removeAll()
        workspace.startApplySequence("fixture: !@F!", files: files, context: applicationContext) { processed.append($0) }
        guard let firstList = lists.first, FileManager.default.fileExists(atPath: firstList.path), processed.isEmpty else {
            throw NetworkError.io("Apply released a plugin list or advanced selection while the plugin was busy.")
        }
        busy = false
        try await waitForOutput { lists.count == 2 }
        guard processed == [file], !FileManager.default.fileExists(atPath: firstList.path),
              FileManager.default.fileExists(atPath: lists[1].path) else {
            throw NetworkError.io("Apply must release each plugin list after completion and prepare the next one afterwards.")
        }
        failure = "fixture plugin failed"; busy = false
        try await waitForOutput { workspace.menuSequence == nil && workspace.pluginWait == nil }
        guard processed == [file], !FileManager.default.fileExists(atPath: lists[1].path) else {
            throw NetworkError.io("A failing plugin must stop Apply and preserve the unprocessed mark.")
        }
        failure = nil
        workspace.startApplySequence("fixture: !@F!", files: files, context: applicationContext) { processed.append($0) }
        guard let lastList = lists.last, workspace.cancelCommandSequence() else {
            throw NetworkError.io("Apply must expose cancellation while an asynchronous plugin runs.")
        }
        try await waitForOutput { workspace.pluginWait == nil }
        guard processed == [file], lists.count == 3, !FileManager.default.fileExists(atPath: lastList.path) else {
            throw NetworkError.io("Cancel must preserve pending marks and clean the plugin list without dispatching another file.")
        }
        return ["History menu delivers Enter, Ctrl+Enter and Shift+Enter to the correct command modes",
                "Combined view/edit history and passive folder navigation receive menu keyboard actions",
                "F2 command runs after Enter without an intermediate preview",
                "Native FarMenu.ini dispatches CommandX lines, continues past nonzero status, honors cd and opens its own source",
                "One association runs directly and multiple matches use the keyboard menu",
                "A missing HLF topic stops CommandX and leaves Apply marks intact",
                "Apply command substitutes each marked filename and waits for async plugin completion before cleanup and advancing",
                "Apply plugin failure and cancellation preserve pending marks and remove temporary files"]
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
    func association(for file: URL, action: UserCommandAction, store: UserCommandStore? = nil,
                     smokeKey: PanelListMenu.SmokeKey? = nil) -> Bool {
        do {
            let ctx = context()
            let explicit = UserCommandContext(currentFile: file, markedFiles: ctx.markedFiles, activeDirectory: ctx.activeDirectory,
                passiveDirectory: ctx.passiveDirectory, passiveCurrentFile: ctx.passiveCurrentFile, passiveMarkedFiles: ctx.passiveMarkedFiles,
                activePanelIsLeft: ctx.activePanelIsLeft, activeDescriptionEncoding: ctx.activeDescriptionEncoding,
                passiveDescriptionEncoding: ctx.passiveDescriptionEncoding)
            let resolution = try (store ?? AppRuntime.commandStore).loadGlobal().resolveAssociations(
                for: file.lastPathComponent, action: action, context: explicit, commands: commandState)
            let entries = resolution.candidates
            guard let first = entries.first else { return resolution.hasMatchingAction }
            let selected: UserAssociationCandidate
            if entries.count == 1 {
                selected = first
            } else {
                let menu = PanelListMenu(title: "Ассоциации · \(file.lastPathComponent)", hint: "Enter — выполнить · Esc — отменить")
                menu.replaceRows(entries.map { .init(title: $0.title) })
                var index: Int?
                menu.onActivate = { [weak menu] row in index = row; menu?.dismiss() }
                menu.run(relativeTo: input.window, smokeKey: smokeKey)
                guard let index else { return true }
                selected = entries[index]
            }
            if let prepared = try prepareUserCommand(selected.template, title: selected.title, context: explicit) {
                executePrepared(prepared, directory: explicit.activeDirectory)
            }
            return true
        } catch { report(error.localizedDescription); return true }
    }
}

@MainActor private final class TerminalHostView: NSView {
    var onLayout: (() -> Void)?
    override func layout() { super.layout(); onLayout?() }
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

extension ShellWorkspace {
    func luaEnvironment(_ name: String) -> String? { commandState.environmentValue(name) }
    func luaSetEnvironment(_ name: String, _ value: String?) throws {
        guard !name.isEmpty, !name.contains("="), !name.contains("\0"), !(value?.contains("\0") ?? false) else { throw ExtensionAPIError("Недопустимое имя или значение переменной окружения") }
        commandState.setEnvironment(name, value: value)
        refreshPrompt()
    }
}
