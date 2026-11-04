import Foundation

/// Polling opens a fresh immutable read-only snapshot. Growing, truncated and
/// atomically replaced files all follow the same validation path; stale snapshots
/// never have their change checks disabled. Page allocation remains bounded.
public enum ViewerTail {
    public struct Update: Sendable {
        public let document: ViewerDocument
        public let offset: Int64
    }
    public static func poll(url: URL, previousIdentity: String?, encoding: ViewerEncoding = .automatic,
                            pageSize: Int = 65_536) throws -> Update? {
        guard pageSize > 0, pageSize <= 65_536 else { throw ViewerError.invalidRange }
        let source = try LocalViewerSource(url: url)
        if source.identity == previousIdentity { try source.verifyUnchanged(); return nil }
        let document = try ViewerDocument(source: source, encoding: encoding)
        // Text may align backwards by up to three bytes; hex rows by fifteen.
        // Leave headroom so the final bounded load reaches EOF after alignment.
        let tailCount = max(1, pageSize - 16)
        return Update(document: document, offset: max(Int64(document.bomLength), source.size - Int64(tailCount)))
    }
}
