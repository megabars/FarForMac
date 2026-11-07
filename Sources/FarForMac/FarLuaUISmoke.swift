import AppKit
import FarCore

extension AppDelegate {
    func runLuaWorkspaceUISmokeChecks() async throws -> [String] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("far-lua-ui-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("alpha\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("beta\n".utf8).write(to: root.appendingPathComponent("b.txt"))
        try Data("A: Macro menu fixture\n  true\n".utf8).write(to: root.appendingPathComponent("FarMenu.ini"))
        let previous = active.directory
        defer { active.navigateHistory(to: previous.path); try? FileManager.default.removeItem(at: root) }
        guard await luaNavigate(root.path, active: true) else { throw ExtensionAPIError("Lua smoke: fixture navigation failed") }
        try await focusMainWindowForSmoke()
        active.focus(); luaShell.input.stringValue = ""
        let host = FarLuaWorkspace.shared, runtime = try FarLuaRuntime()
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let original = try String(contentsOf: sourceRoot.appendingPathComponent("Tests/FarCoreTests/Fixtures/FarLua/Panel.SpaceToSelect.lua"), encoding: .utf8)
        try runtime.load(source: original, name: "Panel.SpaceToSelect.lua", language: .lua, snapshot: host.snapshot())
        _ = try await host.drive(runtime.startChunk(source: "assert(Panel.SetPos(0,'a.txt') > 0)", name: "=smoke-cursor", language: .lua, snapshot: host.snapshot()), runtime: runtime)
        let matches = try runtime.matchingMacros(key: "Space", snapshot: host.snapshot())
        guard let macro = matches.first else { throw ExtensionAPIError("Lua smoke: original condition did not match live panel") }
        _ = try await host.drive(runtime.start(macro, snapshot: host.snapshot(), key: "Space"), runtime: runtime)
        guard active.markedEntries.map(\.name) == ["a.txt"] else { throw ExtensionAPIError("Lua smoke: original Keys(Ins) did not mark real panel row. Focus=\(String(describing: window.firstResponder)) key=\(window.isKeyWindow) marks=\(active.markedEntries.map(\.name)) row=\(active.table.selectedRow)") }
        let result = try await host.drive(runtime.startChunk(source: """
        assert(APanel.Selected and APanel.SelCount == 1)
        assert(Panel.SetPos(0, "b.txt") > 0)
        assert(Panel.Item(0, APanel.CurPos, 0) == "b.txt")
        assert(Panel.Select(0, 0, 0) == 1)
        assert(not APanel.Selected)
        assert(Panel.Select(0, 3) == 1)
        assert(APanel.Selected)
        assert(panel.SetCmdLine(nil, "from-lua"))
        assert(panel.SetCmdLinePos(nil, 6) and panel.GetCmdLinePos() == 6)
        assert(panel.SetCmdLineSelection(nil, 6, 8))
        local first, last = panel.GetCmdLineSelection(nil)
        assert(first == 6 and last == 8)
        assert(panel.InsertCmdLine(nil, "mac") and panel.GetCmdLine() == "from-mac")
        first, last = panel.GetCmdLineSelection(nil)
        assert(first == 1 and last == 0)
        assert(not panel.SetCmdLinePos(nil, -9223372036854775807))
        return panel.GetCmdLine(), mf.substr("A😀B", 1, 2), mf.index("Alpha", "PH")
        """, name: "=live-panel", language: .lua, snapshot: host.snapshot()), runtime: runtime)
        guard result == [.string("from-mac"), .string("😀"), .integer(2)] else { throw ExtensionAPIError("Lua smoke: host results / live snapshots differ") }
        luaShell.input.stringValue = ""; active.clearMarks()
        let moon = try await host.drive(runtime.startChunk(source: "return { APanel.Current, mf.fmatch 'a.txt', '*.txt' }", name: "=moon-ui", language: .moonScript, snapshot: host.snapshot()), runtime: runtime)
        guard moon == [.array([.string("b.txt"), .integer(1)])] else { throw ExtensionAPIError("MoonScript host API failed") }
        let vars = try await host.drive(runtime.startChunk(source: "mf.env('FAR_LUA_SMOKE',1,'yes'); local x=win.GetEnv('FAR_LUA_SMOKE'); mf.env('FAR_LUA_SMOKE',1); return x,win.GetEnv('FAR_LUA_SMOKE')", name: "=environment", language: .lua, snapshot: host.snapshot()), runtime: runtime)
        guard vars == [.string("yes"), .nilValue] else { throw ExtensionAPIError("Lua environment does not share command workspace") }
        var explicitFailure = false
        do { _ = try await host.drive(runtime.startChunk(source: "far.UnsupportedAPICheck()", name: "=unsupported", language: .lua, snapshot: host.snapshot()), runtime: runtime) }
        catch { explicitFailure = error.localizedDescription.contains("UnsupportedAPICheck") }
        guard explicitFailure else { throw ExtensionAPIError("Unknown Lua API must fail explicitly") }
        _ = try await host.drive(runtime.startChunk(source: "Keys('F2'); assert(Area.UserMenu); Keys('Esc')", name: "=nested-menu", language: .lua, snapshot: host.snapshot()), runtime: runtime)
        let menuDeadline = Date().addingTimeInterval(5)
        while NSApp.modalWindow != nil, Date() < menuDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard NSApp.modalWindow == nil else { throw ExtensionAPIError("Lua Keys did not close the nested user menu") }
        let providerChecks = try FarLuaBuiltinPanel.runUISmokeChecks(in: root)
        return providerChecks + ["Unmodified FAR SpaceToSelect executes Keys on real panel", "Lua Keys opens and closes the nested F2 menu in the UserMenu area", "Lua panel state refreshes after selection and cursor host calls", "Lua selection restoration preserves original marked names", "MoonScript executes through live AppKit host", "Lua environment shares shell variables and deletion", "Unknown Lua host API reports an explicit error"]
    }
}
