import Foundation
import Testing
@testable import FarCore

@MainActor
@Suite("Embedded FAR Lua and MoonScript")
struct FarLuaRuntimeTests {
    private let shell = FarLuaSnapshot(area: "Shell", globals: [
        "CmdLine": .table(["Empty": .bool(true)]),
        "APanel": .table(["Visible": .bool(true), "Selected": .bool(false), "Folder": .bool(false)]),
        "PPanel": .table(["Visible": .bool(true), "Selected": .bool(false), "Folder": .bool(true)])
    ])

    @Test("Unmodified FAR Panel.SpaceToSelect uses CmdLine, APanel and Keys")
    func originalLuaMacro() throws {
        let runtime = try FarLuaRuntime()
        let definitions = try runtime.load(source: fixture("Panel.SpaceToSelect.lua"), name: "Panel.SpaceToSelect.lua", language: .lua)
        let macro = try #require(definitions.first)
        #expect(try runtime.matchingMacros(key: "space", snapshot: shell) == [macro])
        #expect(try runtime.matchingMacros(key: "Space", snapshot: .init(area: "Editor")).isEmpty)
        var blocked = shell
        blocked.globals["CmdLine"] = .table(["Empty": .bool(false)])
        #expect(try runtime.matchingMacros(key: "Space", snapshot: blocked).isEmpty)
        #expect(try runtime.start(macro, snapshot: shell) == .request(.init(name: "Keys", arguments: [.string("Ins")])))
        #expect(try runtime.resume(snapshot: shell) == .finished([]))
    }

    @Test("Unmodified FAR Editor.ColorWord compiles and retains macro state between events")
    func originalMoonMacro() throws {
        let runtime = try FarLuaRuntime()
        let editor = FarLuaSnapshot(area: "Editor", globals: [
            "far": .table(["Flags": .table(["ACTL_GETCOLOR": .integer(3), "EE_REDRAW": .integer(2),
                                           "EE_CLOSE": .integer(3), "ECF_AUTODELETE": .integer(1)]),
                           "Colors": .table(["COL_EDITORTEXT": .integer(12)])])
        ], queryResults: [
            "far.AdvControl": .table(["ForegroundColor": .integer(15), "BackgroundColor": .integer(0)])
        ])
        let declarations = try runtime.load(source: fixture("Editor.ColorWord.moon"), name: "Editor.ColorWord.moon",
                                            language: .moonScript, snapshot: editor)
        let macro = try #require(declarations.first { $0.kind == .macro })
        let event = try #require(declarations.first { $0.kind == .event })
        #expect(macro.description == "Color Word Under Cursor")
        #expect(try runtime.matchingMacros(key: "F5", snapshot: editor) == [macro])
        #expect(try runtime.start(macro, snapshot: editor) == .request(.init(name: "editor.GetInfo", arguments: [])))
        let editorInfo: FarLuaValue = .table(["EditorID": .integer(17), "CurPos": .integer(3), "TopScreenLine": .integer(1),
                                             "WindowSizeY": .integer(1), "TotalLines": .integer(1)])
        for args: [FarLuaValue] in [[.integer(0), .integer(4)], [.integer(0), .integer(1)], [.integer(0), .integer(3)]] {
            let results: [FarLuaValue] = args[1] == .integer(4) ? [editorInfo] : [.integer(0)]
            #expect(try runtime.resume(with: results, snapshot: editor) == .request(.init(name: "Editor.Sel", arguments: args)))
        }
        #expect(try runtime.resume(with: [.integer(0)], snapshot: editor) == .request(.init(name: "editor.GetString", arguments: [])))
        #expect(try runtime.resume(with: [.table(["StringText": .string("alpha beta alpha")])], snapshot: editor) == .finished([]))

        let arguments: [FarLuaValue] = [.integer(17), .integer(2), .nilValue]
        #expect(try runtime.matchingEvents(group: "EditorEvent", snapshot: editor, arguments: arguments) == [event])
        #expect(try runtime.start(event, snapshot: editor, arguments: arguments) == .request(.init(name: "editor.GetInfo", arguments: [.integer(17)])))
        #expect(try runtime.resume(with: [editorInfo], snapshot: editor) == .request(.init(name: "editor.GetString", arguments: [.integer(17), .integer(1)])))
        let color: FarLuaValue = .table(["ForegroundColor": .integer(0), "BackgroundColor": .integer(15)])
        let first: [FarLuaValue] = [.integer(17), .integer(1), .integer(1), .integer(5), .integer(1),
                                    color, .integer(100), .string("507CFA2A-3BA3-4F2B-8A80-318F5A831235")]
        #expect(try runtime.resume(with: [.table(["StringText": .string("alpha beta alpha")])], snapshot: editor) ==
                .request(.init(name: "editor.AddColor", arguments: first)))
        var last = first
        last[2] = .integer(12)
        last[3] = .integer(16)
        #expect(try runtime.resume(snapshot: editor) == .request(.init(name: "editor.AddColor", arguments: last)))
        #expect(try runtime.resume(snapshot: editor) == .finished([]))
    }

    @Test("Nested coroutines yield typed requests and receive refreshed snapshots")
    func nestedActions() throws {
        let runtime = try FarLuaRuntime()
        let declarations = try runtime.load(source: """
        Macro { area = "Shell Common"; key = "CtrlF7"; flags = "EmptyCommandLine | NoPFolders";
          condition = function(key, data) assert(key == "RCtrlF7" and data.key == "CtrlF7"); return 80 end;
          action = function()
            return coroutine.wrap(function()
              Keys("2*Down", "Up")
              local result, empty = Plugin.Call("guid", nil, 4)
              print(result, "not printed")
              return empty, APanel.Visible, mf.akey(1)
            end)()
          end }
        """, name: "nested.lua", language: .lua)
        var snapshot = shell
        #expect(try runtime.matchingMacros(key: "RCtrlF7", snapshot: snapshot).isEmpty)
        snapshot.globals["PPanel"] = .table(["Folder": .bool(false)])
        #expect(try runtime.matchingMacros(key: "RCtrlF7", snapshot: snapshot) == declarations)
        let macro = try #require(declarations.first)
        #expect(try runtime.start(macro, snapshot: snapshot, key: "RCtrlF7") == .request(.init(name: "Keys", arguments: [.string("Down")])))
        #expect(try runtime.resume(snapshot: snapshot) == .request(.init(name: "Keys", arguments: [.string("Down")])))
        #expect(try runtime.resume(snapshot: snapshot) == .request(.init(name: "Keys", arguments: [.string("Up")])))
        #expect(try runtime.resume(snapshot: snapshot) == .request(.init(name: "Plugin.Call", arguments: [.string("guid"), .nilValue, .integer(4)])))
        #expect(try runtime.resume(with: [.string("result"), .nilValue], snapshot: snapshot) == .request(.init(name: "print", arguments: [.string("result")])))
        snapshot.globals["APanel"] = .table(["Visible": .bool(false)])
        #expect(try runtime.resume(snapshot: snapshot) == .finished([.nilValue, .bool(false), .string("RCtrlF7")]))
    }

    @Test("Menu and startup declarations are separate from execution")
    func menuAndStartup() throws {
        let runtime = try FarLuaRuntime()
        let declarations = try runtime.load(source: """
        Macro { area = "Common"; key = "F12"; flags = "RunAfterFARStart"; action = function() return "start" end }
        MenuItem { area = "Shell"; menu = "Plugins"; guid = "621A9CB7-A695-4058-8CDE-BC78844C1921";
          text = function(menu, area) return menu .. " / " .. area end;
          action = function() return "menu" end }
        Event { group = "FolderChanged"; priority = 10; condition = function() return 70 end;
          action = function() return "event" end }
        """, name: "menu.lua", language: .lua)
        #expect(declarations.count == 3)
        #expect(!runtime.isRunning)
        #expect(try runtime.startupMacros(snapshot: shell) == [declarations[0]])
        #expect(try runtime.startupMacros(snapshot: shell).isEmpty)
        #expect(try runtime.menuTitle(declarations[1], snapshot: shell) == "Plugins / Shell")
        #expect(try runtime.start(declarations[1], snapshot: shell) == .finished([.string("menu")]))
        #expect(try runtime.matchingEvents(group: "folderchanged", snapshot: shell) == [declarations[2]])
    }

    @Test("Failed load is transactional and direct OS access stays unavailable")
    func invalidLoad() throws {
        let runtime = try FarLuaRuntime()
        #expect(throws: FarLuaError.self) {
            try runtime.load(source: "Macro { area = 'Shell' }; Keys('F4')", name: "bad.lua", language: .lua)
        }
        #expect(throws: FarLuaError.self) {
            try runtime.load(source: "Macro { area = 'Shell'; description = string.char(255) }",
                             name: "bad-utf8.lua", language: .lua)
        }
        #expect(runtime.definitions.isEmpty)
        #expect(try runtime.load(source: """
        assert(io == nil and os.execute == nil and os.remove == nil and debug == nil and dofile == nil and loadfile == nil)
        assert(os.difftime(10, 3) == 7)
        assert(not pcall(require, "ffi"))
        Macro { area = "Shell"; action = function() assert(not load(string.dump(function() end))); return true end }
        """, name: "good.lua", language: .lua).first?.id == 1)
        let macro = try #require(runtime.definitions.first)
        #expect(try runtime.start(macro, snapshot: shell) == .finished([.bool(true)]))
    }

    @Test("Instruction and native pattern limits return errors, even under pcall")
    func limitsAndCancellation() throws {
        let runtime = try FarLuaRuntime()
        #expect(throws: FarLuaError.self) {
            try runtime.startChunk(source: "while true do pcall(function() while true do end end) end",
                                   name: "loop.lua", language: .lua, snapshot: shell)
        }
        #expect(throws: FarLuaError.self) {
            try runtime.startChunk(source: "return string.match(('a'):rep(60), ('a*'):rep(20)..'b')",
                                   name: "pattern.lua", language: .lua, snapshot: shell)
        }
        #expect(try runtime.startChunk(source: "Keys('F4'); error('must not resume')", name: "stop.lua",
                                      language: .lua, snapshot: shell) == .request(.init(name: "Keys", arguments: [.string("F4")])))
        runtime.cancel()
        #expect(throws: FarLuaError.self) { try runtime.resume(snapshot: shell) }
        #expect(try runtime.startChunk(source: "double = (x) -> x*2\nreturn double 21", name: "chunk.moon",
                                      language: .moonScript, snapshot: shell) == .finished([.integer(42)]))
    }

    @Test("LuaFar exports preserve handle identity, callbacks and local modules")
    func pluginExports() throws {
        let runtime = try FarLuaRuntime()
        try runtime.loadModule(source: "return { init = 2 }", name: "fixture.settings", language: .lua)
        try runtime.load(source: """
        local initial = require("fixture.settings").init
        export.Open = function()
          return { count = initial, bump = function(self, n) self.count = self.count + n end }
        end
        function export.GetFindData(object, handle, mode)
          assert(handle == 12 and mode == 3)
          object:bump(1)
          return { { FileName = "count", FileSize = object.count } }
        end
        """, name: "plugin.lua", language: .lua)
        #expect(runtime.hasExport("Open"))
        guard case .finished(let results) = try runtime.startExport("Open", snapshot: shell),
              case .reference(let ref) = results.first else {
            Issue.record("Open failed to return an opaque reference")
            return
        }
        let args: [FarLuaValue] = [.reference(ref), .integer(12), .integer(3)]
        for count in [3, 4] {
            #expect(try runtime.startExport("GetFindData", arguments: args, snapshot: shell) ==
                    .finished([.array([.table(["FileName": .string("count"), "FileSize": .integer(Int64(count))])])]))
        }
        runtime.releaseReference(.reference(ref))
        #expect(throws: FarLuaError.self) {
            try runtime.startExport("GetFindData", arguments: args, snapshot: shell)
        }
    }

    @Test("Invalid callback results release staged references and panel handles stay machine-local")
    func invalidCallbackReferences() throws {
        let runtime = try FarLuaRuntime()
        try runtime.load(source: """
        function export.Open(from)
          if from == 11 then return {type="panel", 7} end
          if from == 4 then return -1 end
          if from == 1 then return 0 end
        end
        function export.GetOpenPanelInfo(object, handle)
          assert(type(handle) == "userdata")
          return object
        end
        function export.GetFindData()
          local rows = {}
          for i = 1, 3000 do rows[i] = {FileName = string.char(255), UserData = {value=i}} end
          return rows
        end
        """, name: "references.lua", language: .lua)
        for _ in 0..<3 {
            do {
                _ = try runtime.startExport("GetFindData", snapshot: shell)
                Issue.record("Expected invalid UTF-8")
            } catch let error as FarLuaError {
                #expect(error.message.contains("valid UTF-8"))
            }
        }
        #expect(try runtime.startExport("Open", arguments: [.integer(4)], snapshot: shell) == .finished([.integer(-1)]))
        guard case .finished(let menuValues) = try runtime.startExport("Open", arguments: [.integer(1)], snapshot: shell),
              let menuPanel = menuValues.first, case .reference = menuPanel else {
            Issue.record("A zero scalar is a truthy Lua panel object")
            return
        }
        runtime.releaseReference(menuPanel)
        guard case .finished(let values) = try runtime.startExport("Open", arguments: [.integer(11)], snapshot: shell),
              let panel = values.first, case .reference = panel else {
            Issue.record("OPEN_FROMMACRO must preserve scalar panel objects")
            return
        }
        let handle = try runtime.makePanelHandle()
        #expect(try runtime.startExport("GetOpenPanelInfo", arguments: [panel, handle], snapshot: shell) == .finished([.integer(7)]))
        let otherRuntime = try FarLuaRuntime()
        let other = try otherRuntime.makePanelHandle()
        #expect(handle != other)
        #expect(throws: FarLuaError.self) {
            try runtime.startExport("GetOpenPanelInfo", arguments: [panel, other], snapshot: shell)
        }
    }

    private func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: "FarLua", withExtension: nil)).appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
