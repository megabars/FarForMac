import Foundation

/// A file operation owns these metadata snapshots, but never owns the user's files.
/// Commit the destination after publication; remove source metadata only after the
/// source itself was removed. Failure is a partial-result warning, never rollback.
public struct FileDescriptionTransfer: Sendable {
    private var source: FileDescriptions
    private var destination: FileDescriptions?
    private let sourceName: String
    private let destinationName: String
    private let value: String?
    private let sameDirectory: Bool

    public static func prepare(source: URL, destination: URL,
                               encodings: [String: FileDescriptionEncoding] = [:]) throws -> Self? {
        // The control file can also be explicitly selected as ordinary user data.
        guard source.lastPathComponent != "descript.ion", destination.lastPathComponent != "descript.ion" else { return nil }
        let from = source.deletingLastPathComponent(), to = destination.deletingLastPathComponent()
        let sourceKey = FileDescriptionEncoding.directoryKey(from), targetKey = FileDescriptionEncoding.directoryKey(to)
        let snapshot = try FileDescriptions.load(directory: from, encoding: encodings[sourceKey] ?? .utf8)
        let value = snapshot.descriptions[source.lastPathComponent]
        let same = sourceKey == targetKey
        let target = value == nil ? nil : (same ? snapshot : try FileDescriptions.load(directory: to, encoding: encodings[targetKey] ?? .utf8))
        return Self(source: snapshot, destination: target, sourceName: source.lastPathComponent,
                    destinationName: destination.lastPathComponent, value: value, sameDirectory: same)
    }

    /// Call only after successful publication. A source without a record leaves
    /// any destination record intact, as FAR's DizList::CopyDiz does.
    public mutating func publishDescription() throws {
        guard let value, var destination else { return }
        try source.verifyCurrent()
        try destination.setDescription(value, for: destinationName)
        self.destination = try destination.save()
        if sameDirectory { source = self.destination! }
    }

    public func verifySourceDescription() throws { try source.verifyCurrent() }

    public mutating func removeSourceDescription() throws {
        guard value != nil, sourceName != destinationName || !sameDirectory else { return }
        try source.setDescription("", for: sourceName)
        source = try source.save()
    }
}

/// Reviewed batch renames retain the original mapping, including completed subsets.
/// Only apply entries whose exclusive filesystem rename actually succeeded.
public struct FileDescriptionRenamePlan: Sendable {
    private let snapshot: FileDescriptions
    public static func prepare(directory: URL, encoding: FileDescriptionEncoding = .utf8) throws -> Self {
        Self(snapshot: try FileDescriptions.load(directory: directory, encoding: encoding))
    }
    public func apply(completedRenames: [(source: String, destination: String)]) throws {
        var result = snapshot
        try snapshot.verifyCurrent()
        for entry in completedRenames where entry.source != "descript.ion" && entry.destination != "descript.ion" {
            if snapshot.descriptions[entry.source] != nil { try result.setDescription("", for: entry.source) }
        }
        for entry in completedRenames where entry.source != "descript.ion" && entry.destination != "descript.ion" {
            if let value = snapshot.descriptions[entry.source] { try result.setDescription(value, for: entry.destination) }
        }
        _ = try result.save()
    }
}
