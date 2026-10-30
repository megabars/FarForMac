import Foundation
import Testing
@testable import FarCore

@Suite
struct SortGroupsTests {
    @Test func firstMatchingRuleWinsAboveAndBelowNeutral() throws {
        let groups = SortGroups(enabled: true, upper: ["README*", "*.md"], lower: ["*.tmp", "*"])
        let ranks = try groups.ranks(for: ["README.md", "notes.md", "scratch.tmp", "other"])
        #expect(ranks == ["README.md": -2, "notes.md": -1, "scratch.tmp": 1, "other": 2])
        let neutral = try SortGroups(enabled: true, upper: ["README*"], lower: ["*.tmp"]).ranks(for: ["ordinary"])
        #expect(neutral == ["ordinary": 0])
    }
    @Test func masksReuseExclusionsRegexAndNamedGroups() throws {
        let groups = SortGroups(enabled: true, upper: ["<source>|test*", "/^test/i"], lower: ["*.bak"])
        let ranks = try groups.ranks(for: ["main.swift", "test.swift", "TEST.txt", "old.bak", "readme"], maskGroups: ["source": "*.swift"])
        #expect(ranks == ["main.swift": -2, "test.swift": -1, "TEST.txt": -1, "old.bak": 1, "readme": 0])
    }
    @Test func disabledSettingsProduceNoRanksAndDefaultsPersist() throws {
        let defaults = SortGroups()
        #expect(try defaults.ranks(for: ["a"]) == [:])
        #expect(try SortGroups.decode(defaults.jsonData()) == defaults)
        let configured = SortGroups(enabled: true, upper: ["<docs>", "*.swift"], lower: ["*.tmp"])
        #expect(try SortGroups.decode(configured.jsonData(), maskGroups: ["docs": "*.md"]) == configured)
    }
    @Test func invalidSettingsAreRejectedBeforeApplyingEvenWhenDisabled() throws {
        for groups in [SortGroups(upper: [""]), SortGroups(upper: ["["]), SortGroups(lower: ["<missing>"]), SortGroups(upper: Array(repeating: "*", count: 101)), SortGroups(upper: [String(repeating: "a", count: 4097)])] {
            #expect(throws: (any Error).self) { try groups.validate() }
        }
        #expect(throws: (any Error).self) { try SortGroups.decode(Data("{\"enabled\":true,\"upper\":[],\"lower\":4}".utf8)) }
        #expect(throws: (any Error).self) { try SortGroups.decode(Data(repeating: 32, count: SortGroups.maximumJSONSize + 1)) }
    }
    @Test func aggregateDeadlineAndInvalidBudgetsFailAtomically() throws {
        let groups = SortGroups(enabled: true, upper: [String(repeating: "?", count: 500)])
        for limit in [0, -1, Double.infinity, Double.nan] {
            #expect(throws: (any Error).self) { try groups.ranks(for: ["a"], timeLimit: limit) }
        }
        #expect(throws: (any Error).self) {
            try groups.ranks(for: Array(repeating: String(repeating: "a", count: 500), count: 1_000), timeLimit: 0.000_001)
        }
    }
}
