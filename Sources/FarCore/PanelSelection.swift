/// A panel's cursor and marks are independent. The parent row has no file ID.
public struct PanelSelection: Sendable {
    public private(set) var cursorID: String?
    public private(set) var markedIDs: Set<String>
    private var savedMarks: Set<String>?

    public var hasSavedMarks: Bool { savedMarks != nil }

    public init() {
        cursorID = nil
        markedIDs = []
        savedMarks = nil
    }

    public mutating func focus(_ id: String?) {
        cursorID = id
    }

    public mutating func toggle(_ id: String) {
        if !markedIDs.insert(id).inserted { markedIDs.remove(id) }
    }

    public mutating func setMarked(_ ids: [String], marked: Bool) {
        if marked {
            markedIDs.formUnion(ids)
        } else {
            markedIDs.subtract(ids)
        }
    }

    public mutating func invert(_ ids: [String]) {
        markedIDs.formSymmetricDifference(Set(ids))
    }

    public mutating func clearMarks() {
        markedIDs.removeAll()
    }

    /// The caller saves once per gesture or bulk action, before changing marks.
    public mutating func saveMarks() {
        savedMarks = markedIDs
    }

    /// Swap the current and previous sets, discarding targets absent from this listing.
    public mutating func restoreMarks(validIDs: [String]) {
        guard let savedMarks else { return }
        let valid = Set(validIDs)
        let current = markedIDs.intersection(valid)
        markedIDs = savedMarks.intersection(valid)
        self.savedMarks = current
    }

    /// Reconcile after a listing change; reset when navigating to another directory.
    public mutating func reconcile(validIDs: [String], reset: Bool = false) {
        if reset {
            cursorID = nil
            markedIDs.removeAll()
            savedMarks = nil
            return
        }
        let valid = Set(validIDs)
        markedIDs.formIntersection(valid)
        savedMarks?.formIntersection(valid)
        if let cursorID, !valid.contains(cursorID) { self.cursorID = nil }
    }

    /// Marks take precedence. Stale marks never cause an operation on the cursor.
    public func operationIDs(orderedIDs: [String]) -> [String] {
        if !markedIDs.isEmpty {
            var seen = Set<String>()
            return orderedIDs.filter { markedIDs.contains($0) && seen.insert($0).inserted }
        }
        guard let cursorID, orderedIDs.contains(cursorID) else { return [] }
        return [cursorID]
    }
}
