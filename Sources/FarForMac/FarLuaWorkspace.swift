import AppKit
import FarCore

enum FarLuaHostContext {
    @TaskLocal static var runtime: FarLuaRuntime?
}

/// Lua code resumes between host operations; the application remains the owner of UI and files.
@MainActor final class FarLuaWorkspace: NSObject {
    static let shared = FarLuaWorkspace()
    weak var app: AppDelegate?
    private(set) var runtime: FarLuaRuntime?
    private var running: Task<Void, Never>?
    private var synthetic: [TimeInterval: UInt16] = [:]
    private var deliveredKeys = Set<TimeInterval>()
    private var lastSyntheticObservation = ""
    private var recording: [String]?
    private var recordedArea = "Shell"
    private var assigningKey = false
    private var errors: [String] = []
    private(set) var lastFailure: String?
    func clearFailure() { lastFailure = nil }
    private var observers: [NSObjectProtocol] = []
    private var startupDone = false
    private var shuttingDown = false
    private var lastWindow: Int?
    private weak var lastInput: NSEvent?
    private var queuedEvents: [(String, [FarLuaValue])] = []
    var isRunning: Bool { running != nil }
    var isRecording: Bool { recording != nil }
    var scriptDirectory: URL {
        let root = AppRuntime.smokeStateDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/FarForMac")
        return root.appendingPathComponent("Macros/scripts", isDirectory: true)
    }
    var area: String {
        if HlfViewerWorkspace.shared.isHelpWindow(NSApp.keyWindow) { return "Help" }
        if let menu = NSApp.modalWindow?.windowController as? PanelListMenu { return menu.macroArea }
        if NSApp.keyWindow?.attachedSheet != nil { return "Dialog" }
        if let modal = NSApp.modalWindow {
            if modal.windowController is TextFileWindow { return "Editor" }
            if modal.windowController is ViewerWindow { return "Viewer" }
            return "Dialog"
        }
        if NSApp.keyWindow?.windowController is TextFileWindow { return "Editor" }
        if NSApp.keyWindow?.windowController is ViewerWindow { return "Viewer" }
        if NSApp.keyWindow === app?.window {
            if app?.farMainMenu.isPresented == true { return "MainMenu" }
            switch app?.active?.contentMode {
            case .tree: return "Tree"
            case .info: return "Info"
            case .quickView: return "QView"
            default: return "Shell"
            }
        }
        return "Other"
    }
    static let flags: [String: FarLuaValue] = {
        var values: [String: FarLuaValue] = [
        "PTYPE_FILEPANEL":.integer(0), "PTYPE_TREEPANEL":.integer(1), "PTYPE_QVIEWPANEL":.integer(2), "PTYPE_INFOPANEL":.integer(3),
        "BTYPE_NONE":.integer(0), "BTYPE_STREAM":.integer(1), "BTYPE_COLUMN":.integer(2),
        "EUR_BEGIN":.integer(0), "EUR_END":.integer(1), "EUR_UNDO":.integer(2), "EUR_REDO":.integer(3),
        "OPEN_LEFTDISKMENU":.integer(0), "OPEN_PLUGINSMENU":.integer(1), "OPEN_FINDLIST":.integer(2), "OPEN_SHORTCUT":.integer(3),
        "OPEN_COMMANDLINE":.integer(4), "OPEN_EDITOR":.integer(5), "OPEN_VIEWER":.integer(6), "OPEN_FILEPANEL":.integer(7), "OPEN_DIALOG":.integer(8), "OPEN_FROMMACRO":.integer(11),
        "EE_READ":.integer(0), "EE_SAVE":.integer(1), "EE_REDRAW":.integer(2), "EE_CLOSE":.integer(3), "EE_GOTFOCUS":.integer(6), "EE_KILLFOCUS":.integer(7), "EE_CHANGE":.integer(8),
        "VE_READ":.integer(0), "VE_CLOSE":.integer(1), "VE_GOTFOCUS":.integer(6), "VE_KILLFOCUS":.integer(7),
        "PF_PRELOAD":.integer(1), "PF_DISABLEPANELS":.integer(2), "PF_EDITOR":.integer(4), "PF_VIEWER":.integer(8), "PF_FULLCMDLINE":.integer(16), "PF_DIALOG":.integer(32),
        "FMSG_WARNING":.integer(1), "FMSG_MB_OK":.integer(0x10000), "FMSG_MB_OKCANCEL":.integer(0x20000),
        "SM_NAME":.integer(2), "SM_EXT":.integer(3), "SM_MTIME":.integer(4), "SM_CTIME":.integer(5), "SM_ATIME":.integer(6), "SM_SIZE":.integer(7),
        "PPIF_SELECTED":.integer(0x40000000), "OPM_SILENT":.integer(1), "OPM_FIND":.integer(2), "OPM_VIEW":.integer(4), "OPM_EDIT":.integer(8)
        ]
        for (key, value) in FarLuaFlags.values { values[key] = .integer(value) }
        return values
    }()
    static var editorColorSnapshot: FarLuaValue {
        func color(_ color: NSColor) -> FarLuaValue {
            let value = color.usingColorSpace(.sRGB) ?? color
            return .integer(0xFF000000 | Int64(value.redComponent * 255) | (Int64(value.greenComponent * 255) << 8) | (Int64(value.blueComponent * 255) << 16))
        }
        return .table(["Flags":.integer(0), "ForegroundColor": color(Palette.text), "BackgroundColor": color(NSColor(calibratedRed:0.035, green:0.065, blue:0.14, alpha:1))])
    }
    func snapshot() -> FarLuaSnapshot {
        let shell = app?.luaShell
        let command = shell.map(commandText) ?? ""
        let selection = shell.map(commandSelection) ?? NSRange(location: 0, length: 0)
        var globals: [String: FarLuaValue] = ["far": .table(["Flags": .table(Self.flags), "Colors": .table(["COL_EDITORTEXT":.integer(53)])]),
            "CmdLine": .table(["Value": .string(command), "Empty": .bool(command.isEmpty), "Selected": .bool(selection.length > 0), "CurPos": .hostInteger(selection.location + 1), "ItemCount": .hostInteger(command.utf16.count), "Bof": .bool(selection.location == 0), "Eof": .bool(selection.location == command.utf16.count)]),
            "APanel": app?.active?.luaPanelProperties ?? .table([:]), "PPanel": app?.passive.luaPanelProperties ?? .table([:]),
            "Far": .table(["PID": .integer(Int64(ProcessInfo.processInfo.processIdentifier)), "Title": .string(NSApp.keyWindow?.title ?? ""), "IsUserAdmin": .bool(geteuid() == 0), "UpTime": .number(ProcessInfo.processInfo.systemUptime), "Width": .hostInteger(Int((NSApp.keyWindow?.contentView?.bounds.width ?? 0) / 8)), "Height": .hostInteger(Int((NSApp.keyWindow?.contentView?.bounds.height ?? 0) / 16))])]
        var calls: [FarLuaQuery] = [
            FarLuaQuery("far.AdvControl", arguments: [.integer(3), .integer(53)], results: [Self.editorColorSnapshot]),
            FarLuaQuery("far.AdvControl", arguments: [.string("ACTL_GETCOLOR"), .integer(53)], results: [Self.editorColorSnapshot])
        ]
        func query(_ name: String, _ arguments: [FarLuaValue], _ result: [FarLuaValue]) {
            calls.append(FarLuaQuery(name, arguments: arguments, results: result))
        }
        for arguments: [FarLuaValue] in [[], [.nilValue]] {
            query("panel.GetCmdLine", arguments, [.string(command)])
            query("panel.GetCmdLinePos", arguments, [.hostInteger(selection.location + 1)])
            query("panel.GetCmdLineSelection", arguments, shell.map { commandSelectionResult(commandSelection($0)) } ?? [.nilValue])
        }
        if let app {
            for (selector, panel) in [(1, app.active), (0, app.passive)] {
                guard let panel else { continue }
                for name in ["panel.GetPanelInfo", "panel.GetPanelDirectory", "panel.GetCurrentPanelItem"] {
                    let args: [FarLuaValue] = [.nilValue, .hostInteger(selector)]
                    if let result = try? panel.luaPanelCall(name, args) {
                        query(name, args, result)
                        query(name, [.hostInteger(selector)], result)
                        if selector == 1 { query(name, [], result); query(name, [.nilValue], result) }
                    }
                }
            }
        }
        if let editor = NSApp.keyWindow?.windowController as? TextFileWindow {
            globals["Editor"] = editor.luaEditorProperties
            for args: [FarLuaValue] in [[], [.nilValue], [.hostInteger(editor.window?.windowNumber ?? 0)]] {
                if let info = try? editor.luaEditorCall("editor.GetInfo", args) { query("editor.GetInfo", args, info) }
                query("editor.GetFileName", args, [.string(editor.workingFileURL?.path ?? "")])
            }
        }
        if let viewer = NSApp.keyWindow?.windowController as? ViewerWindow {
            globals["Viewer"] = viewer.luaViewerProperties
            for args: [FarLuaValue] in [[], [.nilValue], [.hostInteger(viewer.window?.windowNumber ?? 0)]] {
                query("viewer.GetInfo", args, [viewer.luaViewerInfo])
                query("viewer.GetFileName", args, [.string(viewer.sourceFileURL.path)])
            }
        }
        if area == "Dialog" {
            let text = NSApp.keyWindow?.firstResponder as? NSTextView
            globals["Dlg"] = .table(["Selected":.bool((text?.selectedRange().length ?? 0) > 0)])
        }
        return FarLuaSnapshot(area: area, globals: globals, queryCalls: calls)
    }
    func configure(app: AppDelegate) {
        self.app = app
        do { try reload() } catch { report(error) }
        if !AppRuntime.isSmoke {
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let window = note.object as? NSWindow, self.lastWindow != window.windowNumber else { return }
                    self.lastWindow = window.windowNumber
                    if window.windowController is TextFileWindow { self.event("EditorEvent", [.hostInteger(window.windowNumber), .integer(6), .nilValue]) }
                    if window.windowController is ViewerWindow { self.event("ViewerEvent", [.hostInteger(window.windowNumber), .integer(6), .nilValue]) }
                }
            })
            Task { [weak self] in
                guard let self else { return }
                let deadline = Date().addingTimeInterval(60)
                while app.left.loading || app.right.loading {
                    guard Date() < deadline else { self.report(ExtensionAPIError("LuaMacro: стартовые панели не загрузились")); return }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                self.runStartup()
            }
        }
    }
    func reload() throws {
        guard running == nil else { throw MacroError.busy }
        let next = try FarLuaRuntime()
        try loadProfileModules(into: next)
        if FileManager.default.fileExists(atPath: scriptDirectory.path) {
            let urls = try profileScripts(in: scriptDirectory)
            for url in urls where ["lua", "moon"].contains(url.pathExtension.lowercased()) {
                do {
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 1_048_576 else { throw ExtensionAPIError("Макрос должен быть обычным файлом до 1 МиБ: \(url.lastPathComponent)") }
                    let source = try String(contentsOf: url, encoding: .utf8)
                    try next.load(source: source, name: url.path, language: url.pathExtension.lowercased() == "moon" ? .moonScript : .lua, snapshot: snapshot())
                } catch { report(error) }
            }
        }
        runtime = next
    }
    private func profileScripts(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return [] }
        var result: [URL] = [], examined = 0, bytes = 0
        for case let url as URL in enumerator {
            examined += 1
            guard examined <= 4096 else { throw ExtensionAPIError("Слишком много файлов в каталоге макросов") }
            let info = try url.resourceValues(forKeys: keys)
            if info.isSymbolicLink == true || enumerator.level > 8 { enumerator.skipDescendants(); continue }
            if info.isRegularFile == true, FarLuaLanguage(pathExtension: url.pathExtension) != nil {
                let size = info.fileSize ?? Int.max
                guard size <= 1_048_576, size <= 8_388_608 - bytes else { throw ExtensionAPIError("Превышен размер исходников Lua/MoonScript") }
                bytes += size; result.append(url)
            }
        }
        return result.sorted { $0.path < $1.path }
    }
    private func loadProfileModules(into runtime: FarLuaRuntime) throws {
        let directory = scriptDirectory.deletingLastPathComponent().appendingPathComponent("modules", isDirectory: true)
        for file in try profileScripts(in: directory) {
            let relative = String(file.deletingPathExtension().path.dropFirst(directory.path.count + 1))
            let module = relative.replacingOccurrences(of: "/", with: ".")
            let source = try String(contentsOf: file, encoding: .utf8)
            let language = FarLuaLanguage(pathExtension: file.pathExtension)!
            try runtime.loadModule(source: source, name: module, language: language)
            if module.hasSuffix(".init") { try runtime.loadModule(source: source, name: String(module.dropLast(5)), language: language) }
        }
    }
    private func runStartup() {
        guard !startupDone, let runtime else { return }; startupDone = true
        do { play(try runtime.startupMacros(snapshot: snapshot())) } catch { report(error) }
    }
    func handle(_ event: NSEvent) -> Bool {
        if assigningKey { return false }
        if lastInput === event { return false }
        lastInput = event
        if !synthetic.isEmpty { lastSyntheticObservation = "key=\(event.keyCode), time=\(event.timestamp), pending=\(synthetic.keys.sorted())" }
        // AppKit may round timestamps when copying posted events. Match the
        // original token and physical key, retaining that token for the waiter.
        if let token = synthetic.first(where: { $0.value == event.keyCode && abs($0.key - event.timestamp) < 0.000_01 })?.key {
            synthetic.removeValue(forKey: token); deliveredKeys.insert(token); return false
        }
        if CommandWorkspace.shared.macros.isPlaying || CommandWorkspace.shared.macros.isRecording { return false }
        if NSApp.keyWindow?.firstResponder is TerminalTextView { return false }
        if [NSEvent.ModifierFlags.control, [.control, .shift]].contains(event.modifierFlags.intersection([.control, .command, .option, .shift])), event.keyCode == 47 {
            if recording != nil { finishRecording(settings: event.modifierFlags.contains(.shift)) } else if running == nil { recordedArea = area; recording = []; app?.status.stringValue = "● Запись LuaMacro · Ctrl+. — завершить" }
            return true
        }
        if running != nil {
            if event.keyCode == 53, !FarLuaDocumentHost.isWaitingForDocument,
               NSApp.modalWindow == nil, NSApp.keyWindow?.attachedSheet == nil { stop(); return true }
            return false
        }
        if recording != nil {
            guard recording!.count < 4096 else { recording = nil; report(MacroError.tooManySteps); return true }
            if event.modifierFlags.intersection([.control, .command, .option]).isEmpty,
               let chars = event.characters, !chars.isEmpty, chars.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 0xF700 }) {
                recording?.append("print(\(Self.quote(chars)))")
            } else if let key = FarLuaKeys.name(event) { recording?.append("Keys(\(Self.quote(key)))") }
            return false
        }
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.hasMarkedText() || text is TerminalTextView { return false }
        guard let runtime, let key = FarLuaKeys.name(event) else { return false }
        do {
            let matches = try runtime.matchingMacros(key: key, snapshot: snapshot())
            guard !matches.isEmpty else { return false }
            if matches.count == 1 { play(matches, key: key) }
            else { choose(matches, title: "Выбор макроса") }
            return true
        } catch { report(error); return true }
    }
    func stop() { runtime?.cancel(); running?.cancel(); synthetic.removeAll() }
    func shutdown() async {
        shuttingDown = true
        queuedEvents.removeAll()
        let task = running
        stop()
        if let task { await task.value }
        queuedEvents.removeAll()
        guard let runtime else { return }
        do {
            for definition in try runtime.matchingEvents(group: "ExitFAR", snapshot: snapshot(), arguments: [.bool(false)]) {
                _ = try await drive(runtime.start(definition, snapshot: snapshot(), arguments: [.bool(false)]), runtime: runtime)
            }
        } catch { runtime.cancel(); report(error) }
    }
    func hasEventHandlers(_ group: String) -> Bool { runtime?.definitions.contains { $0.kind == .event && $0.group?.lowercased() == group.lowercased() } == true }
    func event(_ group: String, _ args: [FarLuaValue]) {
        guard !shuttingDown, recording == nil, let runtime else { return }
        if running != nil { if queuedEvents.count < 128 { queuedEvents.append((group, args)) }; return }
        do { play(try runtime.matchingEvents(group: group, snapshot: snapshot(), arguments: args), arguments: args) } catch { report(error) }
    }
    private func drainEvents() {
        while running == nil, !queuedEvents.isEmpty { let next = queuedEvents.removeFirst(); event(next.0, next.1) }
    }
    func play(_ definitions: [FarLuaDefinition], arguments: [FarLuaValue] = [], key: String? = nil) {
        guard !definitions.isEmpty, running == nil, let runtime else { return }
        running = Task { [weak self] in
            guard let self else { return }
            defer { self.app?.luaFinishUndoGroups(); self.running = nil; self.synthetic.removeAll(); self.drainEvents() }
            do {
                for definition in definitions {
                    _ = try await self.drive(runtime.start(definition, snapshot: self.snapshot(), arguments: arguments, key: key), runtime: runtime)
                    if definition.kind != .event { self.app?.luaEditor(nil)?.luaRequestRedraw() }
                }
            } catch { runtime.cancel(); self.report(error) }
        }
    }
    func drive(_ initial: FarLuaStep, runtime: FarLuaRuntime) async throws -> [FarLuaValue] {
        var step = initial, requests = 0
        while true {
            try Task.checkCancellation()
            switch step {
            case .finished(let result): return result
            case .request(let request):
                requests += 1
                guard requests <= 100_000 else { runtime.cancel(); throw ExtensionAPIError("Превышено число вызовов API макроса.") }
                let result: Result<[FarLuaValue], Error>
                do { result = .success(try await FarLuaHostContext.$runtime.withValue(runtime) { try await host(request.name, request.arguments) }) }
                catch is CancellationError { runtime.cancel(); throw CancellationError() }
                catch { result = .failure(error) }
                switch result {
                case .success(let values): step = try runtime.resume(with: values, snapshot: snapshot())
                case .failure(let error): step = try runtime.resume(throwing: error.localizedDescription, snapshot: snapshot())
                }
                await Task.yield()
            }
        }
    }
    func host(_ name: String, _ args: [FarLuaValue]) async throws -> [FarLuaValue] {
        if let result = try await utility(name, args) { return result }
        switch name {
        case "Keys":
            guard let key = args.lua(0).hostString else { throw ExtensionAPIError("Keys: требуется имя клавиши") }
            let event = try FarLuaKeys.event(key, window: NSApp.keyWindow)
            let identity = event.timestamp
            lastSyntheticObservation = "Нет событий после постановки клавиши в очередь"
            synthetic[identity] = event.keyCode
            // Schedule outside the suspended Lua action. sendEvent uses the
            // ordinary AppKit monitors; a nested menu can keep pumping its loop
            // while the coroutine supplies the next key.
            perform(#selector(deliverSyntheticKey(_:)), with: event, afterDelay: 0, inModes: [.default, .modalPanel])
            defer {
                NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(deliverSyntheticKey(_:)), object: event)
                synthetic.removeValue(forKey: identity); deliveredKeys.remove(identity)
            }
            let deliveryDeadline = Date().addingTimeInterval(5)
            while !deliveredKeys.contains(identity) {
                guard Date() < deliveryDeadline else { throw ExtensionAPIError("Keys: окно не приняло клавишу \(key). \(lastSyntheticObservation)") }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            await Task.yield()
            let deadline = Date().addingTimeInterval(60)
            while app?.active?.loading == true {
                guard Date() < deadline else { throw ExtensionAPIError("Keys: панель не завершила загрузку за 60 секунд") }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            return []
        case "print":
            guard let text = args.lua(0).hostString else { return [] }
            if let target = NSApp.keyWindow?.firstResponder as? NSTextView { target.insertText(text, replacementRange: target.selectedRange()) }
            else if area == "Shell", let shell = app?.luaShell, insertCommandText(text, into: shell) {}
            else { throw ExtensionAPIError("print: нет активного поля ввода") }
            return []
        case "far.Message": return message(args)
        case "far.Menu": return menu(args)
        case "far.InputBox": return inputBox(args)
        case "far.CopyToClipboard": NSPasteboard.general.clearContents(); return [.bool(NSPasteboard.general.setString(args.lua(0).hostString ?? "", forType: .string))]
        case "far.PasteFromClipboard": return [.string(NSPasteboard.general.string(forType: .string) ?? "")]
        case "far.MacroGetArea": return [.hostInteger(["Other","Shell","Viewer","Editor","Dialog","Search","Disks","MainMenu","Menu","Help","Info","QView","Tree","FindFolder","UserMenu"].firstIndex(of: area) ?? 0)]
        case "far.GetCurrentDirectory": return [.string(app?.active.directory.path ?? FileManager.default.currentDirectoryPath)]
        case "far.LStricmp", "far.LStrnicmp":
            let a = args.lua(0).hostString ?? "", b = args.lua(1).hostString ?? ""
            let length = args.lua(2).hostInt ?? max(a.count, b.count)
            return [.integer(Int64(String(a.prefix(max(0, length))).localizedCaseInsensitiveCompare(String(b.prefix(max(0, length)))).rawValue))]
        case "far.NameToInputRecord":
            guard let key = args.lua(0).hostString else { throw ExtensionAPIError("far.NameToInputRecord: ожидается имя клавиши") }
            return [FarLuaInputRecord.record(named: key)]
        case "far.InputRecordToName":
            guard args.lua(0).table != nil else { throw ExtensionAPIError("far.InputRecordToName: ожидается INPUT_RECORD") }
            return FarLuaInputRecord.name(of: args.lua(0), split: args.lua(1).hostBool)
        case "far.AdvControl":
            guard args.lua(0).hostInt == 3, args.lua(1).hostInt == 53 else { throw ExtensionAPIError("far.AdvControl: эта команда ещё не перенесена") }
            return [Self.editorColorSnapshot]
        case "far.ShowHelp":
            guard let app else { return [.bool(false)] }
            return [.bool(try HlfViewerWorkspace.shared.showHelp(module: args.lua(0).hostString, topic: args.lua(1).hostString,
                flags: args.lua(2).hostInt ?? 0, directory: app.active.directory, farHome: app.luaFarHome,
                pluginRoots: FarLuaPlugins.shared.pluginRoots))]
        case "panel.GetCmdLine": return [app.map { .string(commandText($0.luaShell)) } ?? .nilValue]
        case "panel.SetCmdLine":
            guard let shell = app?.luaShell, let value = args.lua(1).hostString else { return [.bool(false)] }
            shell.input.stringValue = value
            return [.bool(commandText(shell) == value)]
        case "panel.InsertCmdLine":
            guard let shell = app?.luaShell, let value = args.lua(1).hostString else { return [.bool(false)] }
            return [.bool(insertCommandText(value, into: shell))]
        case "panel.GetCmdLinePos":
            guard let shell = app?.luaShell else { return [.nilValue] }
            return [.hostInteger(commandSelection(shell).location + 1)]
        case "panel.SetCmdLinePos":
            guard let shell = app?.luaShell, let pos = args.lua(1).hostInt, pos > 0,
                  pos - 1 <= commandText(shell).utf16.count else { return [.bool(false)] }
            return [.bool(setCommandSelection(NSRange(location: pos - 1, length: 0), in: shell))]
        case "panel.GetCmdLineSelection":
            guard let shell = app?.luaShell else { return [.nilValue] }
            return commandSelectionResult(commandSelection(shell))
        case "panel.SetCmdLineSelection":
            guard let shell = app?.luaShell, let start = args.lua(1).hostInt, let end = args.lua(2).hostInt else { return [.bool(false)] }
            if start <= 0 || end < 0 {
                return [.bool(setCommandSelection(NSRange(location: commandSelection(shell).location, length: 0), in: shell))]
            }
            guard end >= start - 1, end <= commandText(shell).utf16.count else { return [.bool(false)] }
            return [.bool(setCommandSelection(NSRange(location: start - 1, length: end - (start - 1)), in: shell))]
        case "panel.CheckPanelsExist": return [.bool(app != nil)]
        case "panel.SetPanelDirectory":
            guard let app, let panel = panelTarget(args) else { return [.bool(false)] }
            let directory = args.lua(2).hostTable
            let path = args.lua(2).hostString ?? directory["Name"]?.hostString ?? ""
            if let id = directory["PluginId"]?.hostString.flatMap(UUID.init(uuidString:)),
               id != Self.farID {
                guard let view = panel.resourceView as? FarLuaPluginPanelView, view.plugin.guid == id else { return [.bool(false)] }
                return [.bool(try await view.navigate(path))]
            }
            return [.bool(await app.luaNavigate(path, active: panel === app.active))]
        case "panel.SetActivePanel":
            guard let panel = panelTarget(args), let app else { return [.bool(false)] }
            app.activate(panel); panel.focus()
            return [.bool(true)]
        case "panel.UpdatePanel":
            guard let app, let panel = panelTarget(args) else { return [.bool(false)] }
            if let view = panel.resourceView as? FarLuaPluginPanelView {
                return [.bool(try await view.refreshFromHost())]
            }
            return [.bool(await app.luaRefresh(active: panel === app.active))]
        case "panel.ClosePanel":
            guard let panel = panelTarget(args, supportsSecond: false) else { return [.bool(false)] }
            if panel.isResource { panel.leaveResource() }
            else if panel.isRemote { panel.leaveRemote() }
            else if panel.isArchive { panel.leaveArchive() }
            else { return [.bool(false)] }
            return [.bool(true)]
        case "Plugin.Call", "Plugin.SyncCall", "Plugin.Command", "Plugin.Menu", "Plugin.Config", "Plugin.Exist", "Plugin.Load", "Plugin.Unload":
            return try await FarLuaPlugins.shared.call(name, args)
        case "editor.Editor", "viewer.Viewer":
            guard let app else { throw ExtensionAPIError("Окно FarForMac недоступно") }
            return try await FarLuaDocumentHost.call(name, args, app: app)
        default:
            if name.hasPrefix("viewer.") {
                guard let viewer = app?.luaViewer(args.lua(0).hostInt) else { return [.nilValue] }
                return try await viewer.luaViewerCall(name, args)
            }
            if name.hasPrefix("editor.") || name.hasPrefix("Editor.") {
                guard let editor = app?.luaEditor(name.hasPrefix("Editor.") ? nil : args.lua(0).hostInt) else { return [.nilValue] }
                return try editor.luaEditorCall(name, args)
            }
            if name.hasPrefix("panel.") {
                if let plugin = FarLuaPlugins.shared.pluginPanel(handle: args.lua(0)) {
                    return try plugin.panelCall(name, args)
                }
                guard let panel = panelTarget(args) else { return [.nilValue] }
                return try panel.luaPanelCall(name, args)
            }
            throw ExtensionAPIError("API пока не перенесён: \(name)")
        }
    }
    private static let farID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    private func commandText(_ shell: ShellWorkspace) -> String {
        (shell.input.currentEditor() as? NSTextView)?.string ?? shell.input.stringValue
    }

    private func commandSelection(_ shell: ShellWorkspace) -> NSRange {
        let length = commandText(shell).utf16.count
        if let range = (shell.input.currentEditor() as? NSTextView)?.selectedRange(),
           range.location <= length, range.length <= length - range.location { return range }
        return NSRange(location: length, length: 0)
    }

    private func commandSelectionResult(_ range: NSRange) -> [FarLuaValue] {
        guard range.length > 0 else { return [.integer(1), .integer(0)] }
        return [.hostInteger(range.location + 1), .hostInteger(NSMaxRange(range))]
    }

    private func setCommandSelection(_ range: NSRange, in shell: ShellWorkspace) -> Bool {
        if commandSelection(shell) == range { return true }
        guard let window = shell.input.window, window.isKeyWindow, shell.input.isEnabled else { return false }
        if shell.input.currentEditor() == nil { shell.focusCommand() }
        guard let editor = shell.input.currentEditor() as? NSTextView else { return false }
        editor.setSelectedRange(range)
        return editor.selectedRange() == range
    }

    private func insertCommandText(_ value: String, into shell: ShellWorkspace) -> Bool {
        guard shell.input.isEnabled, shell.input.isEditable else { return false }
        let selection = commandSelection(shell)
        let text = (commandText(shell) as NSString).replacingCharacters(in: selection, with: value)
        if let editor = shell.input.currentEditor() as? NSTextView {
            editor.insertText(value, replacementRange: selection)
        } else {
            shell.input.stringValue = text
        }
        return commandText(shell) == text
    }

    @objc private func deliverSyntheticKey(_ event: NSEvent) {
        guard synthetic[event.timestamp] != nil else { return }
        NSApp.sendEvent(event)
    }

    private func panelTarget(_ arguments: [FarLuaValue], supportsSecond: Bool = true) -> PanelView? {
        guard let app else { return nil }
        let argument = arguments.lua(0)
        if case .reference = argument {
            guard let view = FarLuaPlugins.shared.pluginPanel(handle: argument), let panel = view.owner,
                  panel.resourceView === view else { return nil }
            return panel
        }
        let side = argument.hostInt ?? (supportsSecond ? arguments.lua(1).hostInt : nil) ?? 1
        return side % 2 == 0 ? app.passive : app.active
    }

    private func message(_ args: [FarLuaValue]) -> [FarLuaValue] {
        let alert = NSAlert(); alert.messageText = args.lua(1).hostString ?? "FarForMac"; alert.informativeText = args.lua(0).hostString ?? ""
        let buttons = (args.lua(2).hostString ?? "OK").split(separator: ";").map(String.init)
        for button in buttons.prefix(12) { alert.addButton(withTitle: button) }
        if buttons.isEmpty { alert.addButton(withTitle: "OK") }
        let value = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 1
        return [.hostInteger(value > 0 && value <= max(1, buttons.count) ? value : -1)]
    }
    private func menu(_ args: [FarLuaValue]) -> [FarLuaValue] {
        let props = args.lua(0).hostTable, items = args.lua(1).hostArray
        guard items.count <= 100_000 else { return [.nilValue] }
        let menu = PanelListMenu(title: props["Title"]?.hostString ?? "Меню", hint: props["Bottom"]?.hostString ?? "Enter — выбрать · Esc — отмена")
        menu.replaceRows(items.map { .init(title: $0.hostTable["text"]?.hostString ?? $0.hostString ?? "", selectable: !($0.hostTable["disabled"]?.hostBool ?? false) && !($0.hostTable["separator"]?.hostBool ?? false)) }, selection: max(1, min(items.count, props["SelectIndex"]?.hostInt ?? 1)) - 1)
        var result: Int?, breakItem: FarLuaValue?
        menu.onActivate = { result = $0; menu.dismiss() }
        menu.onKey = { event in
            guard let key = FarLuaKeys.name(event) else { return false }
            if let item = args.lua(2).hostArray.first(where: { ($0.hostTable["BreakKey"]?.hostString ?? "").replacingOccurrences(of: "C+", with: "Ctrl").replacingOccurrences(of: "A+", with: "Alt").replacingOccurrences(of: "S+", with: "Shift").lowercased() == key.lowercased() }) {
                breakItem = item; result = menu.selection; menu.dismiss(); return true
            }
            return false
        }
        defer { menu.onActivate = nil; menu.onKey = nil }
        menu.run(relativeTo: NSApp.keyWindow)
        guard let result, items.indices.contains(result) else { return [.nilValue] }
        return [breakItem ?? items[result], .hostInteger(result + 1)]
    }
    private func inputBox(_ args: [FarLuaValue]) -> [FarLuaValue] {
        let field = NSTextField(string: args.lua(4).hostString ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 460, height: 24)
        let alert = NSAlert(); alert.messageText = args.lua(1).hostString ?? "Ввод"; alert.informativeText = args.lua(2).hostString ?? ""
        alert.accessoryView = field; alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Отмена")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? [.string(field.stringValue)] : [.nilValue]
    }
    @objc func showBrowser() { choose(runtime?.definitions ?? [], title: "Macro Browser", browser: true) }
    private func choose(_ definitions: [FarLuaDefinition], title: String, browser: Bool = false) {
        let menu = PanelListMenu(title: title, hint: browser ? "Enter — выполнить · F3 — сведения · F4 — исходник · Ctrl+R — перечитать" : "Enter — выполнить · Esc — отмена")
        menu.replaceRows(definitions.map { .init(title: "\($0.areas.joined(separator: ","))  \($0.keys.joined(separator: " "))  \($0.description)") })
        var chosen: Int?, edit: String?, reload = false
        menu.onActivate = { chosen = $0; menu.dismiss() }
        menu.onKey = { [weak self] event in
            guard browser, let self else { return false }
            if event.keyCode == 15, event.modifierFlags.contains(.control) { reload = true; menu.dismiss(); return true }
            guard let index = menu.selection, definitions.indices.contains(index) else { return false }
            if event.keyCode == 118 { edit = definitions[index].name; menu.dismiss(); return true }
            if event.keyCode == 99 { _ = self.message([.string(definitions[index].name + "\n" + definitions[index].flags.joined(separator: " ")), .string(definitions[index].description)]); return true }
            return false
        }
        defer { menu.onActivate = nil; menu.onKey = nil }
        menu.run(relativeTo: NSApp.keyWindow)
        if let edit { app?.luaOpenFile(URL(fileURLWithPath: edit), editable: true) }
        if reload { do { try self.reload(); showBrowser() } catch { report(error) } }
        if let chosen, definitions.indices.contains(chosen) { play([definitions[chosen]]) }
    }
    @objc func importScript() {
        let panel = NSOpenPanel(); panel.title = "Макрос Lua / MoonScript"; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard ["lua","moon"].contains(url.pathExtension.lowercased()) else { throw ExtensionAPIError("Выберите .lua или .moon") }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else { throw ExtensionAPIError("Ожидается UTF-8 файл до 1 МиБ") }
            let check = try FarLuaRuntime(); try loadProfileModules(into: check); try check.load(source: text, name: url.path, language: url.pathExtension == "moon" ? .moonScript : .lua, snapshot: snapshot())
            try FileManager.default.createDirectory(at: scriptDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
            let destination = scriptDirectory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try data.write(to: destination, options: .withoutOverwriting); try reload()
            app?.status.stringValue = "Загружено макросов: \(runtime?.definitions.count ?? 0)"
        } catch { report(error) }
    }
    private func finishRecording(settings showSettings: Bool) {
        guard let lines = recording else { return }; recording = nil
        guard !lines.isEmpty else { return }
        assigningKey = true; defer { assigningKey = false }
        guard let key = FarLuaRecordingDialog.key() else { return }
        do {
            _ = try FarLuaKeys.event(key, window: nil)
            var body = lines.joined(separator: "\n  "), description = "Записанный макрос", flags = ""
            if showSettings {
                guard let settings = FarLuaRecordingDialog.settings(key: key, sequence: body) else { return }
                body = settings.sequence; description = settings.description; flags = settings.flags
            }
            let code = "Macro { area = \(Self.quote(recordedArea)); key = \(Self.quote(key)); flags = \(Self.quote(flags)); description = \(Self.quote(description)); action = function()\n  " + body + "\nend; }\n"
            let validation = try FarLuaRuntime(); try loadProfileModules(into: validation)
            try validation.load(source: code, name: "=recorded", language: .lua, snapshot: snapshot())
            try FileManager.default.createDirectory(at: scriptDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
            try code.write(to: scriptDirectory.appendingPathComponent("recorded-\(UUID().uuidString).lua"), atomically: true, encoding: .utf8)
            try reload()
        } catch { report(error) }
    }
    static func quote(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\t", with: "\\t").replacingOccurrences(of: "\0", with: "\\000") + "\""
    }
    func report(_ error: Error) {
        lastFailure = error.localizedDescription
        let value = String(error.localizedDescription.prefix(4096)); errors.insert(value, at: 0)
        if errors.count > 100 { errors.removeLast() }
        app?.status.stringValue = "LuaMacro: " + value
    }
}

extension FarLuaWorkspace {
    func executePrefix(_ prefix: String, _ arguments: String) -> Bool {
        guard ["lua", "moon", "lm"].contains(prefix.lowercased()) else { return false }
        guard running == nil, let runtime else { report(MacroError.busy); return true }
        if prefix.lowercased() == "lm" {
            switch arguments.trimmingCharacters(in: .whitespaces).lowercased() {
            case "", "browser": showBrowser()
            case "load": do { try reload() } catch { report(error) }
            default: report(ExtensionAPIError("Команда lm не перенесена: \(arguments)"))
            }
            return true
        }
        running = Task { [weak self] in
            guard let self else { return }
            defer { self.app?.luaFinishUndoGroups(); self.running = nil; self.drainEvents() }
            do {
                _ = try await drive(runtime.startChunk(source: arguments, name: "=" + prefix + ":", language: prefix.lowercased() == "moon" ? .moonScript : .lua, snapshot: snapshot()), runtime: runtime)
            } catch { runtime.cancel(); report(error) }
        }
        return true
    }
}
