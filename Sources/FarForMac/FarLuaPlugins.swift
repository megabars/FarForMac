import AppKit
import FarCore

@MainActor
final class FarLuaPlugins {
    static let shared = FarLuaPlugins()

    struct MenuEntry {
        let title: String
        let guid: UUID
    }

    @MainActor
    final class Plugin {
        let runtime: FarLuaRuntime
        let source: URL
        let guid: UUID
        let title: String
        let metadata: [String: FarLuaValue]
        let flags: Int64
        let prefixes: [String]
        let menus: [MenuEntry]
        let configuration: [MenuEntry]
        let disks: [MenuEntry]

        init(runtime: FarLuaRuntime, source: URL, guid: UUID, title: String,
             metadata: [String: FarLuaValue], info: [String: FarLuaValue]) {
            self.runtime = runtime
            self.source = source
            self.guid = guid
            self.title = title
            self.metadata = metadata
            flags = FarLuaPlugins.flags(info["Flags"])
            prefixes = (info["CommandPrefix"]?.hostString ?? "")
                .split(separator: ":").map { $0.lowercased() }
                .filter { !$0.isEmpty && !$0.contains(where: \.isWhitespace) }
            menus = Self.menuEntries(info, "PluginMenu")
            configuration = Self.menuEntries(info, "PluginConfig")
            disks = Self.menuEntries(info, "DiskMenu")
        }

        func supports(area: String) -> Bool {
            switch area {
            case "Editor": return flags & 0x4 != 0
            case "Viewer": return flags & 0x8 != 0
            case "Dialog": return flags & 0x20 != 0
            default: return flags & 0x2 == 0
            }
        }

        func invoke(_ name: String, _ args: [FarLuaValue] = []) async throws -> [FarLuaValue] {
            guard runtime.hasExport(name) else { throw ExtensionAPIError("\(title): export.\(name) отсутствует.") }
            let workspace = FarLuaWorkspace.shared
            let initial = try runtime.startExport(name, arguments: args, snapshot: workspace.snapshot())
            do { return try await workspace.drive(initial, runtime: runtime) }
            catch { runtime.cancel(); throw error }
        }

        private static func menuEntries(_ info: [String: FarLuaValue], _ name: String) -> [MenuEntry] {
            let titles = info[name + "Strings"]?.hostArray.compactMap(\.hostString) ?? []
            let guidValue = info[name + "Guids"] ?? .nilValue
            let guidStrings: [String]
            if let list = guidValue.array {
                guidStrings = list.compactMap(\.hostString)
            } else if let string = guidValue.string, string.utf8.count % 36 == 0 {
                var remaining = string[...]
                var result: [String] = []
                while !remaining.isEmpty {
                    result.append(String(remaining.prefix(36)))
                    remaining = remaining.dropFirst(min(36, remaining.count))
                }
                guidStrings = result
            } else {
                guidStrings = []
            }
            return zip(titles, guidStrings).compactMap { title, guid in
                guard !title.isEmpty, let identifier = UUID(uuidString: guid) else { return nil }
                return MenuEntry(title: title, guid: identifier)
            }
        }
    }

    private weak var app: AppDelegate?
    private var plugins: [Plugin] = []
    var pluginRoots: [UUID: URL] {
        Dictionary(uniqueKeysWithValues: plugins.map { plugin in
            let directory = (try? plugin.source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            return (plugin.guid, directory ? plugin.source : plugin.source.deletingLastPathComponent())
        })
    }
    private var panels: [FarLuaPluginPanelView] = []
    private var operation: Task<Void, Never>?
    var isWorking: Bool { operation != nil }
    var canChangePanelResource: Bool { app?.canChangePanelResource == true }
    private(set) var lastFailure: String?
    func clearFailure() { lastFailure = nil }
    private var editSessions: [FarLuaPluginEditSession] = []
    private let installedPreference = "luafar.installedSources"
    private var installedSources: [String] {
        get { Array((AppPreferences.defaults.stringArray(forKey: installedPreference) ?? []).prefix(32)) }
        set { AppPreferences.defaults.set(newValue, forKey: installedPreference) }
    }

    private var profileDirectory: URL {
        let profile = AppRuntime.smokeStateDirectory ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/FarForMac")
        return profile.appendingPathComponent("Plugins", isDirectory: true)
    }

    func configure(app: AppDelegate) {
        self.app = app
        for path in installedSources where path.hasPrefix("/") {
            do { _ = try load(URL(fileURLWithPath: path)) }
            catch { FarLuaWorkspace.shared.report(error) }
        }
    }

    private struct PluginAction {
        let id: String
        let title: String
        var info: String = ""
        var configure: (() -> Void)?
        let activate: () -> Void
    }

    func showMenu() {
        guard operation == nil else { return }
        let workspace = FarLuaWorkspace.shared
        let area = workspace.area
        let snapshot = workspace.snapshot()
        var actions: [PluginAction] = []
        if let editor = NSApp.keyWindow?.windowController as? TextFileWindow {
            actions.append(.init(id: "builtin.autowrap", title: "AutoWrap", configure: { AutoWrapWorkspace.show() },
                                 activate: { editor.showAutoWrapSettings() }))
            if editor.isEditable {
                actions.append(.init(id: "builtin.drawline", title: "DrawLine", activate: { editor.startDrawLine() }))
            }
            if let item = HlfViewerWorkspace.shared.menuEntry(for: editor) {
                actions.append(.init(id: "builtin.hlfviewer", title: item.title,
                                     configure: { HlfViewerWorkspace.shared.configure() }, activate: item.activate))
            }
            let titles = ["Brackets", "EditCase", "Align"]
            for (index, title) in titles.enumerated() where index == 0 || editor.isEditable {
                actions.append(.init(id: "builtin." + title.lowercased(), title: title, activate: {
                    ExtensionWorkspace.shared.showEditorPlugins(editor, selectedAction: index)
                }))
            }
        }
        actions.append(.init(id: "builtin.luamacro", title: "LuaMacro", activate: { workspace.showBrowser() }))
        if let app {
            for item in StockPanelPlugins.shared.menuEntries(app: app, area: area) {
                actions.append(.init(id: "builtin.stock." + item.title, title: item.title, activate: item.activate))
            }
        }
        if let runtime = workspace.runtime, !runtime.isRunning {
            let items = runtime.definitions.filter {
                $0.kind == .menuItem
                    && $0.menu?.split(whereSeparator: \.isWhitespace).contains(where: { $0.lowercased() == "plugins" }) == true
                    && $0.areas.contains { $0.caseInsensitiveCompare(area) == .orderedSame || $0.lowercased() == "common" }
            }
            for item in items {
                do {
                    guard let title = try runtime.menuTitle(item, snapshot: snapshot), !title.isEmpty else { continue }
                    actions.append(.init(id: "macro." + (item.guid ?? String(item.id)), title: title,
                                         info: item.name + "\n" + item.description, activate: { workspace.play([item]) }))
                } catch { workspace.report(error) }
            }
        }
        let openFrom = Self.menuArea(area)
        for plugin in plugins where plugin.supports(area: area) {
            let information = [plugin.metadata["Description"]?.hostString, plugin.metadata["Author"]?.hostString,
                               plugin.source.path, plugin.guid.uuidString].compactMap { $0 }.joined(separator: "\n")
            for entry in plugin.menus {
                let configure: (() -> Void)? = plugin.configuration.isEmpty ? nil : { [weak self] in
                    self?.configure(plugin)
                }
                actions.append(.init(id: plugin.guid.uuidString + ":" + entry.guid.uuidString,
                                     title: entry.title, info: information, configure: configure, activate: {
                    [weak self, weak panel = app?.active] in
                    self?.perform {
                        _ = try await self?.open(plugin, from: openFrom, guid: entry.guid, data: .integer(0), panel: panel)
                    }
                }))
            }
        }
        runPluginMenu(actions)
    }

    private static let hotkeysPreference = "luafar.pluginMenuHotkeys"

    private func runPluginMenu(_ actions: [PluginAction]) {
        guard !actions.isEmpty else { return }
        var hotkeys = AppPreferences.defaults.dictionary(forKey: Self.hotkeysPreference) as? [String: String] ?? [:]
        let menu = PanelListMenu(title: "Команды плагинов", hint: "Enter — открыть · F3 — сведения · F4 — клавиша · Shift+F9 — настройка")
        func update(selection: Int = 0) {
            menu.replaceRows(actions.map { item in
                let hotkey = hotkeys[item.id].map { $0.uppercased() + "   " } ?? ""
                return .init(title: hotkey + item.title)
            }, selection: selection)
        }
        update()
        var action: (() -> Void)?
        menu.onActivate = { index in action = actions[index].activate; menu.dismiss() }
        menu.onKey = { [weak self] event in
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if modifiers == [.option, .shift], event.keyCode == 101 {
                action = { self?.showConfiguration() }; menu.dismiss(); return true
            }
            guard let index = menu.selection else { return false }
            let item = actions[index]
            if modifiers == [.shift], event.keyCode == 101 {
                if let configure = item.configure { action = configure; menu.dismiss() }
                return true
            }
            guard modifiers.isEmpty else { return false }
            if event.keyCode == 99 {
                let alert = NSAlert()
                alert.messageText = item.title
                alert.informativeText = item.info
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return true
            }
            if event.keyCode == 118, let key = self?.chooseHotkey(for: item, current: hotkeys[item.id]) {
                hotkeys.removeValue(forKey: item.id)
                if !key.isEmpty {
                    let used = actions.filter { hotkeys[$0.id]?.caseInsensitiveCompare(key) == .orderedSame }.map(\.id)
                    for id in used { hotkeys.removeValue(forKey: id) }
                    hotkeys[item.id] = key
                }
                AppPreferences.defaults.set(hotkeys, forKey: Self.hotkeysPreference)
                update(selection: index)
                return true
            }
            if event.keyCode == 118 { return true }
            if let key = event.charactersIgnoringModifiers,
               let match = actions.first(where: { hotkeys[$0.id]?.caseInsensitiveCompare(key) == .orderedSame }) {
                action = match.activate; menu.dismiss(); return true
            }
            return false
        }
        menu.run(relativeTo: NSApp.keyWindow)
        menu.onActivate = nil
        menu.onKey = nil
        action?()
    }

    private func chooseHotkey(for item: PluginAction, current: String?) -> String? {
        let field = NSTextField(string: current ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        let alert = NSAlert()
        alert.messageText = item.title
        alert.informativeText = "Введите одну клавишу. Пустое поле удаляет назначение."
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Отмена")
        while alert.runModal() == .alertFirstButtonReturn {
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count <= 1, value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                return value
            }
            NSSound.beep()
        }
        return nil
    }

    private func configure(_ plugin: Plugin) {
        guard let item = chooseEntry(plugin.configuration, guid: nil, title: plugin.title) else { return }
        perform { _ = try await plugin.invoke("Configure", [.string(item.guid.uuidString)]) }
    }

    func diskMenuEntries(for panel: PanelView) -> [(title: String, activate: () -> Void)] {
        let workspace = FarLuaWorkspace.shared
        var entries: [(String, () -> Void)] = []
        if let app, let sameFolder = StockPanelPlugins.shared.diskMenuEntry(app: app, panel: panel) {
            entries.append(sameFolder)
        }
        if let runtime = workspace.runtime, !runtime.isRunning {
            for item in runtime.definitions where item.kind == .menuItem {
                guard item.menu?.split(whereSeparator: \.isWhitespace)
                    .contains(where: { $0.lowercased() == "disks" }) == true else { continue }
                do {
                    guard let title = try runtime.menuTitle(item, snapshot: workspace.snapshot(), menu: "Disks") else { continue }
                    entries.append((title, { [weak self, weak panel] in
                        if let panel { self?.app?.activate(panel); workspace.play([item]) }
                    }))
                } catch { workspace.report(error) }
            }
        }
        let from: Int64 = panel.locationKey == "left" ? 0 : 10
        for plugin in plugins {
            for item in plugin.disks {
                entries.append((item.title, { [weak self, weak panel] in
                    guard let self, let panel else { return }
                    self.perform {
                        _ = try await self.open(plugin, from: from, guid: item.guid, data: .integer(0), panel: panel)
                    }
                }))
            }
        }
        return entries
    }

    func executePrefix(_ prefix: String, _ arguments: String) -> Bool {
        guard let plugin = plugins.first(where: { $0.prefixes.contains(prefix.lowercased()) }) else { return false }
        clearFailure()
        if operation != nil {
            let error = ExtensionAPIError("LuaFar уже выполняет команду.")
            lastFailure = error.localizedDescription
            FarLuaWorkspace.shared.report(error)
            return true
        }
        let panel = app?.active
        perform {
            _ = try await self.open(plugin, from: 4, guid: nil, data: .string(arguments), panel: panel)
        }
        return true
    }

    func call(_ name: String, _ args: [FarLuaValue]) async throws -> [FarLuaValue] {
        let id = args.lua(0).hostString ?? ""
        if name == "Plugin.Load" {
            guard !id.isEmpty else { return [.bool(false)] }
            let path = URL(fileURLWithPath: id, relativeTo: profileDirectory).standardizedFileURL
            let root = profileDirectory.resolvingSymlinksInPath().standardizedFileURL.path
            let resolved = path.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(root + "/") else {
                throw ExtensionAPIError("Plugin.Load: путь должен находиться в каталоге Plugins профиля.")
            }
            remember(try load(resolved).source)
            return [.bool(true)]
        }
        guard let guid = UUID(uuidString: id) else { return [.bool(false)] }
        if guid == HlfViewerWorkspace.guid {
            switch name {
            case "Plugin.Exist": return [.bool(true)]
            case "Plugin.Config": HlfViewerWorkspace.shared.configure(); return [.bool(true)]
            case "Plugin.Call", "Plugin.SyncCall", "Plugin.Menu":
                guard let editor = NSApp.keyWindow?.windowController as? TextFileWindow else { return [.bool(false)] }
                return [.bool(HlfViewerWorkspace.shared.showCurrentTopic(editor))]
            default: return [.bool(false)]
            }
        }
        guard let plugin = plugins.first(where: { $0.guid == guid }) else { return [.bool(false)] }
        switch name {
        case "Plugin.Exist": return [.bool(true)]
        case "Plugin.Unload":
            guard !plugin.runtime.isRunning else { throw ExtensionAPIError("Плагин выполняет callback.") }
            guard !editSessions.contains(where: { $0.pluginID == plugin.guid }) else {
                throw ExtensionAPIError("Сначала закройте рабочие копии этого плагина.")
            }
            for panel in panels.filter({ $0.plugin === plugin }) {
                await panel.finish()
                if panel.owner?.resourceView === panel { panel.owner?.leaveResource() }
            }
            if plugin.runtime.hasExport("ExitFAR") { _ = try await plugin.invoke("ExitFAR") }
            plugins.removeAll { $0 === plugin }
            installedSources.removeAll { $0 == plugin.source.path }
            return [.bool(true)]
        case "Plugin.Call", "Plugin.SyncCall":
            return try await open(plugin, from: 11, guid: nil, data: .array(Array(args.dropFirst())), panel: app?.active)
        case "Plugin.Command":
            guard let command = args.lua(1).hostString else { return [.bool(false)] }
            _ = try await open(plugin, from: 4, guid: nil, data: .string(command), panel: app?.active)
            return [.bool(true)]
        case "Plugin.Menu":
            let menu = args.lua(1).hostString.flatMap(UUID.init(uuidString:))
            let item = chooseEntry(plugin.menus, guid: menu, title: plugin.title)
            guard let item else { return [.bool(false)] }
            _ = try await open(plugin, from: Self.menuArea(FarLuaWorkspace.shared.area),
                               guid: item.guid, data: .integer(0), panel: app?.active)
            return [.bool(true)]
        case "Plugin.Config":
            let menu = args.lua(1).hostString.flatMap(UUID.init(uuidString:))
            guard let item = chooseEntry(plugin.configuration, guid: menu, title: plugin.title) else { return [.bool(false)] }
            return try await plugin.invoke("Configure", [.string(item.guid.uuidString)])
        default: throw ExtensionAPIError("Неизвестный LuaFar вызов: \(name)")
        }
    }

    func stop() {
        operation?.cancel()
        for panel in panels { panel.cancelPending() }
    }

    func confirmCloseEditors() -> Bool {
        guard !editSessions.contains(where: \.isWorking) else {
            FarLuaWorkspace.shared.report(ExtensionAPIError("Дождитесь отправки рабочей копии LuaFar."))
            return false
        }
        return true
    }

    func commitEditorsForTermination() async throws {
        for session in editSessions { try await session.uploadSaved() }
    }

    func shutdown() async {
        stop()
        if let operation { await operation.value }
        let sessions = editSessions
        for session in sessions { session.cleanup() }
        for panel in panels {
            await panel.finish()
            if panel.owner?.resourceView === panel { panel.owner?.leaveResource(focus: false) }
        }
        panels.removeAll()
        for plugin in plugins where plugin.runtime.hasExport("ExitFAR") {
            do { _ = try await plugin.invoke("ExitFAR") }
            catch { FarLuaWorkspace.shared.report(error) }
        }
        plugins.removeAll()
    }

    func openEditor(_ url: URL, workspace: RemoteWorkspace, original: Data, title: String, pluginID: UUID,
                    commit: @escaping @MainActor (Data, Data, String, String) async throws -> Void,
                    onClosed: @escaping @MainActor () -> Void) throws {
        guard let app else { throw ExtensionAPIError("Окно редактора недоступно.") }
        let editor = try app.luaOpenWorkingCopy(url)
        let session = FarLuaPluginEditSession(editor: editor, workspace: workspace, url: url, original: original,
                                             title: title, pluginID: pluginID, commit: commit, onClosed: { [weak self] closed in
            self?.editSessions.removeAll { $0 === closed }
            onClosed()
        })
        editSessions.append(session)
        session.open()
    }

    func detach(_ panel: FarLuaPluginPanelView) {
        panels.removeAll { $0 === panel }
    }

    func activate(_ panel: PanelView) { app?.activate(panel) }

    func otherPanel(_ panel: PanelView) -> PanelView? {
        guard let app else { return nil }
        return panel === app.left ? app.right : app.left
    }

    func openViewer(_ url: URL, workspace: RemoteWorkspace) -> Bool {
        guard app?.luaOpenFile(url, editable: false) == true,
              let viewer = NSApp.windows.first(where: { $0.representedURL == url })?.windowController as? ViewerWindow else {
            return false
        }
        viewer.retainedRemoteWorkspace = workspace
        return true
    }

    func pluginPanel(handle: FarLuaValue) -> FarLuaPluginPanelView? {
        guard case .reference = handle else { return nil }
        return panels.first { $0.ownsHandle(handle) && $0.plugin.runtime === FarLuaHostContext.runtime }
    }

    static func flags(_ value: FarLuaValue?) -> Int64 {
        guard let value else { return 0 }
        if let number = value.integer { return number }
        if let names = value.string {
            return names.split { $0.isWhitespace || "|,+".contains($0) }
                .reduce(0) { $0 | (FarLuaFlags.values[String($1)] ?? 0) }
        }
        return value.array?.reduce(0) { $0 | flags($1) } ?? 0
    }

    func pluginPanel(on panel: PanelView) -> FarLuaPluginPanelView? {
        panels.first { panel.resourceView === $0 }
    }

    private func open(_ plugin: Plugin, from: Int64, guid: UUID?, data: FarLuaValue,
                      panel: PanelView?) async throws -> [FarLuaValue] {
        let values = try await plugin.invoke("Open", [.integer(from), guid.map { .string($0.uuidString) } ?? .nilValue, data])
        let object = values.lua(0)
        if from == 11 {
            guard case .reference = object else { return values }
        } else {
            guard object.hostBool, object.hostInt != -1 else { return [] }
        }
        guard let panel, plugin.runtime.hasExport("GetFindData") else {
            plugin.runtime.releaseReference(object)
            return []
        }
        let handle = try plugin.runtime.makePanelHandle()
        let view = FarLuaPluginPanelView(owner: panel, plugin: plugin, object: object, handle: handle)
        do { try await view.reload() }
        catch { await view.finish(); throw error }
        panel.showResource(view, kind: .plugin, caption: view.caption,
            focus: { [weak view] in view?.focus() },
            refresh: { [weak view] in view?.refresh() },
            stop: { [weak view] in view?.stop() },
            setActive: { [weak view] in view?.setActive($0) },
            perform: { [weak view] in view?.perform(function: $0, shifted: $1) ?? false })
        panel.resourceParent = { [weak view] in view?.parent() }
        panels.append(view)
        return from == 11 ? [.bool(true)] : []
    }

    private func choosePlugin() {
        let panel = NSOpenPanel()
        panel.title = "Скрипт или каталог LuaFar-плагина"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = profileDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { remember(try load(url).source) } catch { FarLuaWorkspace.shared.report(error) }
    }

    func loadFromCommand(_ url: URL) throws {
        if url.pathExtension.caseInsensitiveCompare("dll") == .orderedSame {
            throw ExtensionAPIError("Загрузка DLL Windows недоступна. Выберите LuaFar-скрипт или каталог.")
        }
        remember(try load(url).source)
    }

    func unloadFromCommand(_ operand: String, directory: URL) async throws {
        let identifier = UUID(uuidString: operand.trimmingCharacters(in: CharacterSet(charactersIn: "{}")))
        let source = FarCmdsFiles.resolve(operand, relativeTo: directory)
        guard let plugin = plugins.first(where: { $0.guid == identifier || $0.source == source }) else {
            throw ExtensionAPIError("LuaFar-плагин не загружен: " + operand)
        }
        _ = try await call("Plugin.Unload", [.string(plugin.guid.uuidString)])
    }

    private func remember(_ source: URL) {
        guard !installedSources.contains(source.path), installedSources.count < 32 else { return }
        installedSources.append(source.path)
    }

    private func chooseUnload() {
        let candidates = plugins
        guard let index = pick("Выгрузить плагин", titles: candidates.map(\.title)) else { return }
        let plugin = candidates[index]
        perform { _ = try await self.call("Plugin.Unload", [.string(plugin.guid.uuidString)]) }
    }

    @discardableResult
    private func load(_ source: URL) throws -> Plugin {
        let source = source.standardizedFileURL
        if let existing = plugins.first(where: { $0.source == source }) { return existing }
        guard plugins.count < 32 else { throw ExtensionAPIError("Достигнут предел LuaFar-плагинов.") }
        let runtime = try FarLuaRuntime()
        let snapshot = FarLuaWorkspace.shared.snapshot()
        let kind = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard kind.isSymbolicLink != true else { throw ExtensionAPIError("LuaFar-плагин должен быть обычным файлом или каталогом.") }
        let moduleDirectory = kind.isDirectory == true ? source : source.deletingLastPathComponent()
        var startup: [String: FarLuaValue] = ["ModuleName": .string(source.path), "ModuleDir": .string(moduleDirectory.path + "/")]
        try runtime.setPluginStartupInfo(startup)
        if kind.isDirectory == true {
            try loadDirectory(source, runtime: runtime, snapshot: snapshot)
        } else {
            try loadScript(source, runtime: runtime, snapshot: snapshot, firstStart: true)
        }
        let metadata = try metadata("GetGlobalInfo", runtime: runtime, snapshot: snapshot)
        guard let rawGuid = metadata["Guid"]?.hostString, let guid = UUID(uuidString: rawGuid),
              let title = metadata["Title"]?.hostString, !title.isEmpty, runtime.hasExport("Open") else {
            throw ExtensionAPIError("LuaFar требует GetGlobalInfo с Guid и Title и callback Open.")
        }
        guard !plugins.contains(where: { $0.guid == guid }) else {
            throw ExtensionAPIError("LuaFar-плагин с GUID \(guid.uuidString) уже загружен.")
        }
        startup["PluginGuid"] = .string(guid.uuidString)
        try runtime.setPluginStartupInfo(startup)
        let info = try runtime.hasExport("GetPluginInfo")
            ? self.metadata("GetPluginInfo", runtime: runtime, snapshot: snapshot) : [:]
        let plugin = Plugin(runtime: runtime, source: source, guid: guid, title: title, metadata: metadata, info: info)
        plugins.append(plugin)
        return plugin
    }

    private func metadata(_ callback: String, runtime: FarLuaRuntime, snapshot: FarLuaSnapshot) throws -> [String: FarLuaValue] {
        guard case .finished(let values) = try runtime.startExport(callback, snapshot: snapshot),
              let result = values.first?.table else {
            runtime.cancel()
            throw ExtensionAPIError("LuaFar: \(callback) должен вернуть таблицу метаданных без действий интерфейса.")
        }
        return result
    }

    private func loadDirectory(_ directory: URL, runtime: FarLuaRuntime, snapshot: FarLuaSnapshot) throws {
        let directoryName = directory.lastPathComponent
        let candidates = [directoryName + ".lua", directoryName + ".moon", "init.lua", "init.moon"]
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        let top = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        guard let boot = candidates.lazy.compactMap({ candidate in top.first { $0.lastPathComponent == candidate } }).first else {
            throw ExtensionAPIError("LuaFar: не найден основной скрипт \(directoryName).lua или init.lua.")
        }
        let global = directory.appendingPathComponent("_globalinfo.lua")
        let excluded = Set([boot.path, global.path])
        var count = 0, total = 0
        if let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for case let file as URL in enumerator {
                count += 1
                guard count <= 256 else { throw ExtensionAPIError("Слишком много файлов в каталоге LuaFar.") }
                let properties = try file.resourceValues(forKeys: Set(keys))
                if properties.isSymbolicLink == true || enumerator.level > 8 {
                    enumerator.skipDescendants()
                    continue
                }
                guard properties.isRegularFile == true, !excluded.contains(file.path),
                      let language = FarLuaLanguage(pathExtension: file.pathExtension) else { continue }
                total += properties.fileSize ?? 0
                guard total <= 8 * 1024 * 1024 else { throw ExtensionAPIError("Слишком большой каталог LuaFar.") }
                let relative = file.deletingPathExtension().path.dropFirst(directory.path.count + 1)
                let module = relative.replacingOccurrences(of: "/", with: ".")
                let source = try Self.readScript(file)
                try runtime.loadModule(source: source, name: module, language: language)
                if module.hasSuffix(".init") {
                    try runtime.loadModule(source: source, name: String(module.dropLast(5)), language: language)
                }
            }
        }
        if manager.fileExists(atPath: global.path) { try loadScript(global, runtime: runtime, snapshot: snapshot) }
        try loadScript(boot, runtime: runtime, snapshot: snapshot, firstStart: true)
    }

    private func loadScript(_ url: URL, runtime: FarLuaRuntime, snapshot: FarLuaSnapshot,
                            firstStart: Bool = false) throws {
        guard let language = FarLuaLanguage(pathExtension: url.pathExtension) else {
            throw ExtensionAPIError("Ожидается скрипт Lua (.lua) или MoonScript (.moon).")
        }
        try runtime.load(source: Self.readScript(url), name: url.path, language: language, snapshot: snapshot,
                         arguments: firstStart ? [.bool(true)] : [])
    }

    private static func readScript(_ url: URL) throws -> String {
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        let limit = 1024 * 1024
        guard properties.isRegularFile == true, properties.isSymbolicLink != true, (properties.fileSize ?? Int.max) <= limit else {
            throw ExtensionAPIError("LuaFar: требуется обычный файл до 1 МиБ.")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit, let source = String(data: data, encoding: .utf8) else {
            throw ExtensionAPIError("LuaFar: неверный размер или кодировка UTF-8.")
        }
        return source
    }

    func showConfiguration() {
        var entries: [(title: String, activate: () -> Void)] = [
            ("Такая же папка", { StockPanelPlugins.shared.configureSameFolder() }),
            ("AutoWrap", { AutoWrapWorkspace.show() }),
            ("HlfViewer", { HlfViewerWorkspace.shared.configure() }),
            ("FAR Commands", { FarCmdsWorkspace.shared.showConfiguration() })
        ]
        for plugin in plugins {
            for item in plugin.configuration {
                entries.append((item.title, { [weak self] in
                    self?.perform { _ = try await plugin.invoke("Configure", [.string(item.guid.uuidString)]) }
                }))
            }
        }
        entries.append(("Загрузить LuaFar-плагин…", { [weak self] in self?.choosePlugin() }))
        if !plugins.isEmpty {
            entries.append(("Выгрузить LuaFar-плагин…", { [weak self] in self?.chooseUnload() }))
        }
        if let index = pick("Настройка плагинов", titles: entries.map(\.title)) { entries[index].activate() }
    }

    private func chooseEntry(_ entries: [MenuEntry], guid: UUID?, title: String) -> MenuEntry? {
        if let guid { return entries.first { $0.guid == guid } }
        if entries.count <= 1 { return entries.first }
        return pick(title, titles: entries.map(\.title)).map { entries[$0] }
    }

    private func pick(_ title: String, titles: [String]) -> Int? {
        let menu = PanelListMenu(title: title, hint: "Enter — выбрать · Esc — отмена")
        menu.replaceRows(titles.map { .init(title: $0) })
        var chosen: Int?
        menu.onActivate = { chosen = $0; menu.dismiss() }
        defer { menu.onActivate = nil }
        menu.run(relativeTo: NSApp.keyWindow)
        return chosen
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard operation == nil else { return }
        operation = Task { [weak self] in
            defer { self?.operation = nil }
            do { try await action() }
            catch is CancellationError { self?.lastFailure = "Команда LuaFar остановлена." }
            catch {
                self?.lastFailure = error.localizedDescription
                FarLuaWorkspace.shared.report(error)
            }
        }
    }

    private static func menuArea(_ area: String) -> Int64 {
        switch area {
        case "Editor": return 5
        case "Viewer": return 6
        case "Dialog": return 8
        default: return 1
        }
    }
}

extension FarLuaPlugins {
    static func runUISmokeChecks() async throws -> [String] {
        let registry = shared
        guard let app = registry.app else { throw ExtensionAPIError("LuaFar smoke: missing application") }
        let owner = app.passive
        let originalActive = app.active
        defer { if let originalActive { app.activate(originalActive); originalActive.focus() } }
        guard !owner.isResource, !owner.isRemote, !owner.isVirtual, !owner.isArchive else {
            throw ExtensionAPIError("LuaFar smoke: expected a local passive panel")
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FarLuaPluginSmoke-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Fixture.lua")
        let backend = folder.appendingPathComponent("backend", isDirectory: true)
        try FileManager.default.createDirectory(at: backend, withIntermediateDirectories: false)
        try Data("first\n".utf8).write(to: backend.appendingPathComponent("file.txt"))
        try Data("input\n".utf8).write(to: folder.appendingPathComponent("new.txt"))
        let source = #"""
        assert((...) == true)
        local startup = far.PluginStartupInfo()
        assert(type(startup.ModuleName) == "string" and type(startup.ModuleDir) == "string")
        local backend = startup.ModuleDir .. "backend/"
        local id = win.Uuid("A5CB240F-9499-44CE-8C74-507E48C7F00D")
        local menu = win.Uuid("2E9A1E9D-EF18-489B-BDFD-731AF6AF0804")
        local didClose = false
        function export.GetGlobalInfo()
          return { Guid = id, Title = "LuaFar Fixture", Version = { 1, 0, 0, 0 } }
        end
        function export.GetPluginInfo()
          assert(far.PluginStartupInfo().PluginGuid == id)
          return { CommandPrefix = "luafar-fixture"; PluginMenuStrings = {"Fixture menu"}; PluginMenuGuids = menu;
                   DiskMenuStrings = {"Fixture disk"}; DiskMenuGuids = menu }
        end
        function export.Open(from, guid, data)
          if from == 11 then return data[1], didClose end
          assert(from == 4 and data == "fixture")
          return { path = "/", rows = {
            {FileName = "folder"; FileAttributes = "d"; UserData = { get = function() return "/folder" end }};
            {FileName = "file.txt"; FileSize = 6}
          }}
        end
        function export.GetOpenPanelInfo(object, handle)
          assert(type(handle) == "userdata")
          return { CurDir = object.path, PanelTitle = "LuaFar Fixture " .. object.path, Flags = 8 }
        end
        function export.GetFindData(object, handle, mode)
          assert(type(handle) == "userdata" and mode == 0)
          return object.rows
        end
        function export.SetDirectory(object, handle, path, mode, data)
          assert(type(handle) == "userdata" and mode == 0 and data.get() == "/folder")
          object.path = data.get()
          return true
        end
        function export.GetFiles(object, handle, items, move, dest, mode)
          assert(type(handle) == "userdata" and items[1].FileName == "file.txt")
          assert(not move and type(dest) == "string" and (mode == 4 or mode == 9))
          assert(win.CopyFile(backend .. "file.txt", dest .. "/file.txt", true))
          return 1, dest
        end
        function export.PutFiles(object, handle, items, move, src, mode)
          assert(type(handle) == "userdata" and not move and type(src) == "string")
          local item = items[1]
          if mode == 8 then
            assert(item.FileName == "file.txt")
            assert(win.CopyFile(src .. "/file.txt", backend .. "file.txt", false))
            object.rows[2].FileSize = item.FileSize
          else
            assert(mode == 0 and item.FileName == "new.txt")
            assert(win.CopyFile(src .. "/new.txt", backend .. "new.txt", true))
            table.insert(object.rows, item)
          end
          return 1
        end
        function export.MakeDirectory(object, handle, dummy, mode)
          assert(type(handle) == "userdata" and dummy == "" and mode == 0)
          table.insert(object.rows, {FileName = "created", FileAttributes = "d"})
          return 1, "created"
        end
        function export.DeleteFiles(object, handle, items, mode)
          assert(type(handle) == "userdata" and items[1].FileName == "created" and mode == 0)
          table.remove(object.rows)
          return true
        end
        function export.ProcessPanelInput(object, handle, input)
          local info = panel.GetPanelInfo(handle)
          assert(info.PluginHandle == handle and info.PluginObject == object and info.OwnerGuid == id)
          local ctrl, alt, shift, key = far.InputRecordToName(input, true)
          assert(ctrl == false and alt == false and shift == "Shift" and key == "Up")
          local converted = far.NameToInputRecord(far.InputRecordToName(input))
          assert(converted.VirtualKeyCode == input.VirtualKeyCode and converted.Name == nil)
          assert(far.InputRecordToName(converted) == "ShiftUp")
          assert(far.NameToInputRecord("NoSuchFarKey") == nil)
          return type(handle) == "userdata" and input.EventType == 1 and input.KeyDown and input.VirtualKeyCode == 0x26
        end
        function export.ClosePanel(object, handle)
          assert(type(handle) == "userdata" and object.path == "/folder")
          assert(type(win.GetCurrentDir()) == "string")
          didClose = true
        end
        """#
        try source.write(to: url, atomically: true, encoding: .utf8)
        let plugin = try registry.load(url)
        defer {
            if let view = registry.pluginPanel(on: owner) {
                view.closeNow()
                if owner.resourceView === view { owner.leaveResource(focus: false) }
            }
            registry.plugins.removeAll { $0 === plugin }
        }
        guard plugin.prefixes == ["luafar-fixture"], plugin.menus.map(\.title) == ["Fixture menu"],
              registry.diskMenuEntries(for: owner).contains(where: { $0.title == "Fixture disk" }) else {
            throw ExtensionAPIError("LuaFar smoke: menu or prefix metadata did not register")
        }
        _ = try await registry.open(plugin, from: 4, guid: nil, data: .string("fixture"), panel: owner)
        guard let view = registry.pluginPanel(on: owner), owner.resourceView === view,
              owner.luaPanelProperties.table?["Plugin"] == .bool(true) else {
            throw ExtensionAPIError("LuaFar smoke: plugin did not open in requested panel")
        }
        try await view.runCallbackSmoke(folder: folder)
        try await view.runEditSmoke(backend: backend)
        await view.finish()
        if owner.resourceView === view { owner.leaveResource(focus: false) }
        let result = try await registry.call("Plugin.Call", [.string(plugin.guid.uuidString), .string("return value")])
        guard result == [.string("return value"), .bool(true)], owner.resourceView == nil else {
            throw ExtensionAPIError("LuaFar smoke: ClosePanel or macro return value was lost")
        }
        return ["LuaFar GetGlobalInfo/GetPluginInfo register command and disk menu",
                "LuaFar Open installs plugin panel in the requested pane",
                "LuaFar file callbacks preserve object, handle, UserData and transfer bytes",
                "LuaFar F4 publishes saved working bytes on editor close and preserves the open callback after panel detach",
                "LuaFar ClosePanel and Plugin.Call retain callback state"]
    }
}
