import Foundation
import Testing
@testable import FarCore

@Suite struct PanelColumnLayoutTests {
    @Test func savedOrderSurvivesAddedRemovedColumns() throws {
        let layout = try PanelColumnLayout(order: ["size", "old", "name"], widths: ["size": 137, "name": 251])
        let restored = try PanelColumnLayout.decode(layout.encoded())
        #expect(restored == layout)
        #expect(restored.orderedColumns(available: ["name", "size", "modified"]) == ["size", "name", "modified"])
    }
    @Test func rejectsCorruptAndFutureLayouts() throws {
        for text in [#"{"version":1,"order":["name","name"],"widths":{}}"#,
                     #"{"version":1,"order":["name"],"widths":{"name":-1}}"#,
                     #"{"version":2,"order":["name"],"widths":{"name":100}}"#] {
            #expect(throws: (any Error).self) { try PanelColumnLayout.decode(Data(text.utf8)) }
        }
        #expect(throws: (any Error).self) { try PanelColumnLayout(order: ["name"], widths: ["name": .infinity]) }
    }
}
