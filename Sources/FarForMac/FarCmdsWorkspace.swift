import AppKit
import FarCore

@MainActor
final class FarCmdsWorkspace {
    static let shared = FarCmdsWorkspace()
    private static let preferencesKey = "farCmds.options"
    private weak var app: AppDelegate?
    private var operation: Task<Void, Never>?
    private var cancellation: ExtensionCancellation?
    private var temporary: [WeakCopy] = []

    private final class WeakCopy {
        weak var copy: RemoteWorkspace?
        init(_ copy: RemoteWorkspace) { self.copy = copy }
    }

    var isWorking: Bool { operation != nil }
    private(set) var lastFailure: String?

    func clearFailure() { lastFailure = nil }
    private var options: FarCmdsOptions {
        get {
            guard let data = AppPreferences.defaults.data(forKey: Self.preferencesKey) else { return .init() }
            return (try? JSONDecoder().decode(FarCmdsOptions.self, from: data)) ?? .init()
        }
        set { AppPreferences.defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.preferencesKey) }
    }

    func configure(app: AppDelegate) { self.app = app }

    @discardableResult
    func executePrefix(_ prefix: String, _ arguments: String, directory: URL? = nil) -> Bool {
        guard let prefix = FarCmdsPrefix(rawValue: prefix.lowercased()), let app else { return false }
        clearFailure()
        guard operation == nil else {
            lastFailure = "FAR Commands уже выполняет команду."
            app.status.stringValue = lastFailure ?? ""
            return true
        }
        let settings = options
        var environment = app.luaShell.farCmdsEnvironment
        if environment["FARHOME"] == nil { environment["FARHOME"] = Bundle.main.bundleURL.path }
        let command: FarCmdsCommand
        do { command = try FarCmdsCommand(prefix: prefix, arguments: arguments, options: settings, environment: environment) }
        catch {
            lastFailure = error.localizedDescription
            app.status.stringValue = error.localizedDescription
            showHelp(prefix)
            return true
        }
        let base = directory ?? app.active.directory
        let token = ExtensionCancellation()
        cancellation = token
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.operation = nil; self.cancellation = nil }
            do { try await self.execute(command, base: base, options: settings, environment: environment, cancellation: token) }
            catch is CancellationError {
                self.lastFailure = "Команда FAR Commands остановлена."
                app.status.stringValue = self.lastFailure ?? ""
            }
            catch {
                self.lastFailure = error.localizedDescription
                app.status.stringValue = error.localizedDescription
                if case .link(let link) = command.operand, link.showErrors { NSAlert(error: error).runModal() }
            }
        }
        return true
    }

    func stop() {
        cancellation?.cancel()
        operation?.cancel()
    }

    func shutdown() async {
        let task = operation
        stop()
        await task?.value
        for copy in temporary { copy.copy?.cleanup() }
        temporary.removeAll()
    }

    func showConfiguration() {
        let current = options
        let display = NSPopUpButton()
        display.addItems(withTitles: ["Скрыть вывод", "Сохранить вывод терминала", "Показать перехваченный вывод в терминале"])
        display.selectItem(at: current.display.rawValue)
        let streams = NSPopUpButton()
        streams.addItems(withTitles: ["stdout и stderr вместе", "Только stdout", "Только stderr", "stdout и stderr раздельно"])
        streams.selectItem(at: current.stream.rawValue)
        let empty = NSButton(checkboxWithTitle: "Открывать пустой результат команды", target: nil, action: nil)
        empty.state = current.openEmptyOutput ? .on : .off
        let create = NSButton(checkboxWithTitle: "Разрешить редактирование новых файлов", target: nil, action: nil)
        create.state = current.editNewFiles ? .on : .off
        let limit = NSTextField(string: String(current.readLimit))
        let fields = vertical([
            label("Вывод внешних команд"), display, label("Перехват потоков"), streams,
            empty, create, label("Предел чтения файла, байт (0 означает 1 МиБ)"), limit
        ], spacing: 7)
        fields.setFrameSize(NSSize(width: 445, height: 226))
        let alert = NSAlert()
        alert.messageText = "FAR Commands"
        alert.accessoryView = fields
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Отмена")
        while alert.runModal() == .alertFirstButtonReturn {
            let value = limit.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let bytes = value.isEmpty ? 0 : Int(value), bytes >= 0, bytes <= FarCmdsOptions.maximumReadLimit,
               let mode = FarCmdsDisplay(rawValue: display.indexOfSelectedItem),
               let stream = FarCmdsStream(rawValue: streams.indexOfSelectedItem) {
                options = .init(display: mode, stream: stream, openEmptyOutput: empty.state == .on,
                                editNewFiles: create.state == .on, maximumReadBytes: bytes)
                return
            }
            alert.informativeText = "Введите размер от 0 до \(FarCmdsOptions.maximumReadLimit) байт."
        }
    }

    private func showHelp(_ prefix: FarCmdsPrefix) {
        let syntax: [FarCmdsPrefix: String] = [
            .view: "view:файл  или  view:<[1|2|*|?][>|<|+][|папка|]команда",
            .edit: "edit:[строка,столбец] файл  или  edit:<команда",
            .goto: "goto:путь  или  goto:<файл с путём",
            .whereis: "whereis:имя  или  whereis:<файл с именем",
            .clip: "clip:файл  или  clip:<команда",
            .link: "link:[/msg] [/n] [/s] источник назначение",
            .run: "run:файл<[1|2|*|?][>|<|+][|папка|]команда",
            .load: "load:путь к LuaFar  или  load:<файл с путём",
            .unload: "unload:путь или GUID  или  unload:<файл с путём"
        ]
        let alert = NSAlert()
        alert.messageText = "FAR Commands · " + prefix.rawValue
        alert.informativeText = syntax[prefix] ?? prefix.rawValue
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func execute(_ command: FarCmdsCommand, base: URL, options: FarCmdsOptions,
                         environment: [String: String], cancellation: ExtensionCancellation) async throws {
        switch command.operand {
        case .path(let path):
            try await executePath(command, path: path, base: base, options: options, environment: environment)
        case .pathInFile(let source):
            let url = FarCmdsFiles.resolve(source, relativeTo: base)
            let path = try await Task.detached {
                try FarCmdsFiles.path(in: url, maximumBytes: options.readLimit, environment: environment)
            }.value
            try Task.checkCancellation()
            try await executePath(command, path: path, base: base, options: options, environment: environment)
        case .link(let request):
            let source = FarCmdsFiles.resolve(request.source, relativeTo: base)
            let destination = FarCmdsFiles.resolve(request.destination, relativeTo: base)
            try await Task.detached {
                guard let entry = try FileTools.snapshot([source]).first else { throw FarCmdsError("Источник ссылки не найден.") }
                if entry.isDirectory && !request.symbolic { throw FarCmdsError("Для папки используйте символическую ссылку /s.") }
                if cancellation.isCancelled { throw CancellationError() }
                try FileTools.createLink(source: entry, at: destination, symbolic: request.symbolic)
            }.value
            if request.refresh { app?.left.refresh(); app?.right.refresh() }
            app?.status.stringValue = "Ссылка создана: " + destination.path
        case .capture(let request):
            let directory = request.directory.map { FarCmdsFiles.resolve($0, relativeTo: base) } ?? base
            var captureEnvironment = environment
            captureEnvironment["PATH"] = ([directory.path, captureEnvironment["FARHOME"], captureEnvironment["PATH"]].compactMap { $0 }).joined(separator: ":")
            let configuration = captureEnvironment
            app?.status.stringValue = "FAR Commands: выполняется команда."
            let result = try await Task.detached {
                try FarCmdsCaptureRunner().run(request, directory: directory, environment: configuration, cancellation: cancellation)
            }.value
            try Task.checkCancellation()
            if !result.console.isEmpty { app?.luaShell.appendFarCmdsOutput(Self.terminalNewlines(result.console)) }
            switch command.prefix {
            case .clip:
                Self.clip(FarCmdsFiles.text(Data(result.primary.prefix(options.readLimit))))
            case .run:
                guard let target = request.destination else { throw FarCmdsError("Укажите файл назначения run:.") }
                let destination = FarCmdsFiles.resolve(target, relativeTo: base)
                try await Task.detached {
                    if cancellation.isCancelled { throw CancellationError() }
                    try result.primary.write(to: destination, options: .atomic)
                }.value
                app?.left.refresh()
                app?.right.refresh()
            case .edit, .view:
                if let errors = result.standardError {
                    try openOutput(errors, stream: "stderr", command: command, source: request.command, options: options)
                }
                let title = request.stream == .stderr ? "stderr" : result.standardError != nil ? "stdout" : nil
                try openOutput(result.primary, stream: title, command: command, source: request.command, options: options)
            default:
                throw FarCmdsError("Команда не поддерживает перехват вывода.")
            }
            let total = result.primary.count + (result.standardError?.count ?? 0)
            app?.status.stringValue = "FAR Commands: \(total) байт · код \(result.exitCode)"
        }
    }

    private func executePath(_ command: FarCmdsCommand, path: String, base: URL,
                             options: FarCmdsOptions, environment: [String: String]) async throws {
        guard let app else { return }
        let url = FarCmdsFiles.resolve(path, relativeTo: base)
        switch command.prefix {
        case .view, .edit:
            let editable = command.prefix == .edit
            if FileManager.default.fileExists(atPath: url.path) {
                guard app.luaOpenFile(url, editable: editable) else { throw FarCmdsError("Не удалось открыть " + url.path) }
                if editable, let editor = NSApp.windows.first(where: { $0.representedURL?.standardizedFileURL == url })?.windowController as? TextFileWindow {
                    try position(editor, command.position)
                }
            } else if editable && options.editNewFiles {
                let editor = TextFileWindow(newAt: url, encoding: .utf8)
                app.farCmdsRegister(editor)
                editor.showWindow(nil)
                try position(editor, command.position)
            } else {
                throw FarCmdsError("Файл не найден: " + url.path)
            }
        case .clip:
            let data = try await Task.detached { try FarCmdsFiles.read(url, maximumBytes: options.readLimit) }.value
            try Task.checkCancellation()
            Self.clip(FarCmdsFiles.text(data))
        case .goto:
            try await locate(url, enter: path.hasSuffix("/"))
        case .whereis:
            let found = await Task.detached { FarCmdsFiles.search(path, from: base, environment: environment) }.value
            try Task.checkCancellation()
            guard let found else { throw FarCmdsError("Объект не найден: " + path) }
            try await locate(found, enter: path.hasSuffix("/"))
        case .load:
            try FarLuaPlugins.shared.loadFromCommand(url)
        case .unload:
            try await FarLuaPlugins.shared.unloadFromCommand(path, directory: base)
        case .link, .run:
            throw FarCmdsError("Укажите параметры команды " + command.prefix.rawValue)
        }
    }

    private func locate(_ url: URL, enter: Bool) async throws {
        guard let app else { return }
        let panel = app.active!
        var directory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
        let descend = url.path == "/" || (enter && directory.boolValue)
        let target = descend ? url : url.deletingLastPathComponent()
        guard await app.luaNavigate(target.path, active: true) else { throw FarCmdsError("Не удалось открыть " + target.path) }
        if exists, !descend, !panel.isHiddenOrHasHiddenAncestor {
            _ = try panel.luaMacroPanelCall("Panel.SetPos", [.integer(0), .string(url.lastPathComponent)])
        }
    }

    private func openOutput(_ bytes: Data, stream: String?, command: FarCmdsCommand, source: String,
                            options: FarCmdsOptions) throws {
        guard !bytes.isEmpty || options.openEmptyOutput else { return }
        let copy = try RemoteWorkspace()
        let url = copy.directory.appendingPathComponent((stream ?? "output") + ".txt")
        try bytes.write(to: url)
        let title = (stream.map { "\($0): " } ?? "") + source
        try openCopy(url, title: title, editable: command.prefix == .edit, copy: copy, position: command.position)
        temporary.removeAll { $0.copy == nil }
        temporary.append(WeakCopy(copy))
    }

    private func openCopy(_ url: URL, title: String, editable: Bool, copy: RemoteWorkspace,
                          position: FarCmdsCommand.Position? = nil, offset: Int64? = nil,
                          encoding: ViewerEncoding = .automatic) throws {
        guard let app else { return }
        if editable {
            let editor = try TextFileWindow(url: url, initialByteOffset: offset, encoding: encoding, onView: {
                [weak self, weak copy] url, offset, encoding in
                guard let copy else { return false }
                return self?.switchCopy(url, title: title, editable: false, copy: copy, offset: offset, encoding: encoding) ?? false
            })
            editor.retainedRemoteWorkspace = copy
            editor.workingCopyDisplayName = title
            editor.workingCopyDisplayPath = "FAR Commands"
            app.farCmdsRegister(editor)
            editor.showWindow(nil)
            try self.position(editor, position)
        } else {
            let viewer = try ViewerWindow(url: url, initialByteOffset: offset, initialEncoding: encoding, onEdit: {
                [weak self, weak copy] url, offset, encoding in
                guard let copy else { return false }
                return self?.switchCopy(url, title: title, editable: true, copy: copy, offset: offset, encoding: encoding) ?? false
            })
            viewer.retainedRemoteWorkspace = copy
            viewer.window?.title = title + " — Просмотр"
            app.farCmdsRegister(viewer)
            viewer.showWindow(nil)
        }
    }

    private func switchCopy(_ url: URL, title: String, editable: Bool, copy: RemoteWorkspace,
                            offset: Int64, encoding: ViewerEncoding) -> Bool {
        do {
            try openCopy(url, title: title, editable: editable, copy: copy, offset: offset, encoding: encoding)
            return true
        } catch {
            app?.status.stringValue = error.localizedDescription
            return false
        }
    }

    private func position(_ editor: TextFileWindow, _ position: FarCmdsCommand.Position?) throws {
        guard let position else { return }
        _ = try editor.luaEditorCall("editor.SetPosition", [.nilValue, .table([
            "CurLine": .hostInteger(position.line), "CurPos": .hostInteger(position.column)
        ])])
    }

    private static func clip(_ text: String) {
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        if !text.isEmpty { _ = clipboard.setString(text, forType: .string) }
    }

    private static func terminalNewlines(_ data: Data) -> Data {
        var result = Data(), previous: UInt8?
        result.reserveCapacity(data.count)
        for byte in data {
            if byte == 10 && previous != 13 { result.append(13) }
            result.append(byte)
            previous = byte
        }
        return result
    }
}

extension FarCmdsWorkspace {
    static func runUISmokeChecks() async throws -> [String] {
        let workspace = shared
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FarCmdsSmoke-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("capture.txt")
        guard workspace.executePrefix("run", "capture.txt<*printf 'out'; printf 'err' >&2", directory: folder) else {
            throw FarCmdsError("FAR Commands smoke: run prefix not recognized")
        }
        await workspace.operation?.value
        guard workspace.lastFailure == nil, try Data(contentsOf: output) == Data("outerr".utf8) else {
            throw FarCmdsError("FAR Commands smoke: run did not write captured output: " + (workspace.lastFailure ?? ""))
        }
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        _ = workspace.executePrefix("view", "<?printf 'hello'; printf 'warning' >&2", directory: folder)
        await workspace.operation?.value
        let captured = NSApp.windows.filter { !existing.contains(ObjectIdentifier($0)) && $0.windowController is ViewerWindow }
        defer { for window in captured where window.isVisible { window.close() } }
        let urls = captured.compactMap(\.representedURL)
        let contents = try urls.map { try String(contentsOf: $0, encoding: .utf8) }
        guard workspace.lastFailure == nil, Set(contents) == ["hello", "warning"], urls.count == 2 else {
            throw FarCmdsError("FAR Commands smoke: separated streams did not open two viewers: " + (workspace.lastFailure ?? ""))
        }
        for window in captured { window.close() }
        guard urls.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) else {
            throw FarCmdsError("FAR Commands smoke: captured output survived viewer close")
        }
        let input = folder.appendingPathComponent("editor.txt")
        try Data("first\nsecond\n".utf8).write(to: input)
        _ = workspace.executePrefix("edit", "[2,3] editor.txt", directory: folder)
        await workspace.operation?.value
        guard let editor = NSApp.windows.first(where: { $0.representedURL?.standardizedFileURL == input.standardizedFileURL })?.windowController as? TextFileWindow,
              editor.extensionSelection.location == 8 else {
            throw FarCmdsError("FAR Commands smoke: edit position was not applied")
        }
        editor.window?.close()
        return ["FAR Commands run captures both streams into the specified file",
                "FAR Commands view separates streams into real viewers and deletes closed output",
                "FAR Commands edit positions the actual editor cursor"]
    }
}
