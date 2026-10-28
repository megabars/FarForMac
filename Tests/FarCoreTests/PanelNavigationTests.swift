import Foundation
import Testing
@testable import FarCore

@Suite
struct PanelNavigationTests {
    @Test
    func candidateNavigationDoesNotChangeHistoryUntilCommitted() {
        var navigation = PanelNavigation(path: "/a")
        navigation.visit("/b")
        navigation.visit("/c")
        #expect(navigation.backPath == "/b")
        #expect(navigation.position == 2) // Reading a candidate for a failed load changes nothing.
        #expect(navigation.forwardPath == nil)
        navigation.commitBack()
        #expect(navigation.position == 1)
        #expect(navigation.forwardPath == "/c")
        navigation.commitForward()
        navigation.commitForward()
        #expect(navigation.position == 2)
        navigation.commitBack()
        navigation.commitBack()
        navigation.commitBack()
        #expect(navigation.position == 0)
    }

    @Test
    func newVisitDropsForwardHistoryAndCurrentVisitIsNoOp() {
        var navigation = PanelNavigation(path: "/a")
        navigation.visit("/b")
        navigation.visit("/c")
        navigation.commitBack()
        navigation.visit("/b")
        #expect(navigation.forwardPath == "/c")
        navigation.visit("/d")
        #expect(navigation.history == ["/a", "/b", "/d"])
        #expect(navigation.forwardPath == nil)
    }

    @Test
    func historyIsBoundedAndRoundTripsCurrentPosition() throws {
        var navigation = PanelNavigation(path: "/0")
        for index in 1...120 { navigation.visit("/\(index)") }
        #expect(navigation.history.count == 100)
        #expect(navigation.history.first == "/21")
        navigation.commitBack()
        let restored = try JSONDecoder().decode(PanelNavigation.self, from: JSONEncoder().encode(navigation))
        #expect(restored.history == navigation.history)
        #expect(restored.position == navigation.position)
        #expect(restored.backPath == "/118")
        #expect(restored.forwardPath == "/120")
    }

    @Test
    func decodedInvalidStateIsSafeAndConsecutiveDuplicatesAreRemoved() throws {
        let decoder = JSONDecoder()
        for json in ["{}", "{\"history\":[],\"position\":99}", "{\"history\":[\"\"],\"position\":-9}", "{\"history\":17,\"position\":\"bad\"}"] {
            let navigation = try decoder.decode(PanelNavigation.self, from: Data(json.utf8))
            #expect(navigation.history == ["/"])
            #expect(navigation.position == 0)
            #expect(navigation.backPath == nil)
            #expect(navigation.forwardPath == nil)
        }
        let json = "{\"history\":[\"/a\",\"/b\",\"/b\",\"\",\"/c\"],\"position\":2}"
        let navigation = try decoder.decode(PanelNavigation.self, from: Data(json.utf8))
        #expect(navigation.history == ["/a", "/b", "/c"])
        #expect(navigation.position == 1)
    }
}
