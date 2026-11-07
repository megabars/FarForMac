import Testing
@testable import FarCore

@MainActor @Suite struct FarLuaQueryTests {
    @Test func conditionQueriesRespectArgumentsNilAndMultipleReturns() throws {
        let runtime = try FarLuaRuntime()
        let snapshot = FarLuaSnapshot(area: "Shell", queryCalls: [
            FarLuaQuery("panel.GetPanelDirectory", arguments: [.nilValue, .integer(0)], results: [.table(["Name": .string("passive")])]),
            FarLuaQuery("panel.GetPanelDirectory", arguments: [.nilValue, .integer(1)], results: [.table(["Name": .string("active")])]),
            FarLuaQuery("panel.GetCmdLineSelection", results: [.nilValue, .integer(7)])
        ])
        let definitions = try runtime.load(source: """
        Macro {area="Shell"; key="F9"; condition=function()
          assert(panel.GetPanelDirectory(nil,0).Name == 'passive')
          assert(panel.GetPanelDirectory(nil,1).Name == 'active')
          local a,b = panel.GetCmdLineSelection()
          assert(a == nil and b == 7)
          local ok = pcall(panel.GetPanelDirectory, nil, 2)
          assert(not ok)
          return true
        end; action=function() end}
        """, name: "queries.lua", language: .lua, snapshot: snapshot)
        #expect(try runtime.matchingMacros(key: "F9", snapshot: snapshot) == definitions)
        var changed = snapshot
        changed.queryCalls[0].results = [.table(["Name": .string("changed")])]
        #expect(throws: FarLuaError.self) { try runtime.matchingMacros(key: "F9", snapshot: changed) }
    }
}
