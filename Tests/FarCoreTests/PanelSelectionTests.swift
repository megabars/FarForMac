import Testing
@testable import FarCore

@Suite
struct PanelSelectionTests {
    @Test
    func cursorAndMarksAreIndependent() {
        var selection = PanelSelection()
        #expect(selection.cursorID == nil)
        #expect(selection.markedIDs.isEmpty)
        selection.focus("first")
        selection.toggle("second")
        selection.focus("third")
        #expect(selection.cursorID == "third")
        #expect(selection.markedIDs == ["second"])
        selection.focus(nil) // The parent row cannot become an operation target.
        #expect(selection.operationIDs(orderedIDs: ["first", "second"]) == ["second"])
        selection.clearMarks()
        #expect(selection.operationIDs(orderedIDs: ["first", "second"]).isEmpty)
    }

    @Test
    func toggleBulkMarkAndInvertOperateOnSets() {
        var selection = PanelSelection()
        selection.focus("cursor")
        selection.toggle("first")
        selection.toggle("first")
        #expect(selection.markedIDs.isEmpty)
        selection.setMarked(["first", "second", "second"], marked: true)
        selection.setMarked(["second", "absent"], marked: false)
        #expect(selection.markedIDs == ["first"])
        selection.invert(["first", "second", "second", "third"])
        #expect(selection.markedIDs == ["second", "third"])
        selection.clearMarks()
        #expect(selection.markedIDs.isEmpty)
        #expect(selection.cursorID == "cursor")
    }

    @Test
    func operationTargetsUseVisibleOrderAndMarksTakePrecedence() {
        var selection = PanelSelection()
        selection.focus("cursor")
        #expect(selection.operationIDs(orderedIDs: ["cursor", "first"]) == ["cursor"])
        #expect(selection.operationIDs(orderedIDs: ["first"]).isEmpty)
        selection.setMarked(["first", "third", "hidden"], marked: true)
        #expect(selection.operationIDs(orderedIDs: ["third", "cursor", "first", "third"]) == ["third", "first"])
        #expect(selection.operationIDs(orderedIDs: ["cursor"]).isEmpty)
    }

    @Test
    func reconciliationPrunesMarksAndMissingCursorWithoutMovingIt() {
        var selection = PanelSelection()
        selection.focus("first")
        selection.setMarked(["first", "second", "hidden", "deleted"], marked: true)
        selection.reconcile(validIDs: ["second", "first"])
        #expect(selection.cursorID == "first")
        #expect(selection.markedIDs == ["first", "second"])
        selection.reconcile(validIDs: ["second"])
        #expect(selection.cursorID == nil)
        #expect(selection.markedIDs == ["second"])
        selection.reconcile(validIDs: [])
        #expect(selection.markedIDs.isEmpty)
        #expect(selection.operationIDs(orderedIDs: []).isEmpty)
    }

    @Test
    func explicitSnapshotRestoresAndTogglesWithoutChangingCursor() {
        var selection = PanelSelection()
        selection.focus("cursor")
        selection.setMarked(["a", "b"], marked: true)
        #expect(!selection.hasSavedMarks)
        selection.saveMarks()
        selection.clearMarks()
        selection.toggle("c")
        selection.restoreMarks(validIDs: ["a", "b", "c", "cursor"])
        #expect(selection.markedIDs == ["a", "b"])
        #expect(selection.cursorID == "cursor")
        selection.restoreMarks(validIDs: ["a", "b", "c"])
        #expect(selection.markedIDs == ["c"])
    }

    @Test
    func reconciliationPrunesBothSnapshotsAndDirectoryResetDiscardsHistory() {
        var selection = PanelSelection()
        selection.setMarked(["deleted", "a"], marked: true)
        selection.saveMarks()
        selection.clearMarks()
        selection.toggle("b")
        selection.reconcile(validIDs: ["a", "b"])
        selection.restoreMarks(validIDs: ["a", "b", "deleted"])
        #expect(selection.markedIDs == ["a"])
        selection.reconcile(validIDs: ["a", "b"], reset: true)
        #expect(!selection.hasSavedMarks)
        selection.restoreMarks(validIDs: ["a", "b"])
        #expect(selection.markedIDs.isEmpty)
    }

    @Test
    func savedEmptySetIsRestorableAndInvalidIDsCannotReturn() {
        var selection = PanelSelection()
        selection.saveMarks()
        #expect(selection.hasSavedMarks)
        selection.setMarked(["a", "hidden"], marked: true)
        selection.restoreMarks(validIDs: ["a"])
        #expect(selection.markedIDs.isEmpty)
        selection.restoreMarks(validIDs: ["a", "hidden"])
        #expect(selection.markedIDs == ["a"])
    }

    @Test
    func directoryResetClearsCursorAndMarksEvenWhenIDsRemainValid() {
        var selection = PanelSelection()
        selection.focus("first")
        selection.toggle("first")
        selection.reconcile(validIDs: ["first"], reset: true)
        #expect(selection.cursorID == nil)
        #expect(selection.markedIDs.isEmpty)
    }
}
