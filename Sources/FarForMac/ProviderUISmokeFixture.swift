import Foundation
import FarCore

/// Used only by the opt-in isolated AppKit diagnostics; never by a connection window.
final class ProviderUISmokeFixture: RemoteSearchDownloadProvider, RemoteNonRecursiveDirectoryRemoval, RemoteNoReplaceRenameProvider {
    let connection: NetworkConnection
    private(set) var downloads = 0
    var waitForCancellation = false
    var allowsRemoval = false
    private var values: [String: RemoteEntry] = [:]
    private var data: [String: Data] = [:]
    init(name: String = "") {
        connection = NetworkConnection(name: name, kind: .sftp, host: "ui-smoke.invalid", username: "fixture")
        for path in ["/", "/docs", "/target"] {
            values[path] = RemoteEntry(path: path, isDirectory: true, size: 0, version: path)
        }
        add("/docs/alpha.txt", text: "first\nneedle α\n")
        add("/docs/beta.txt", text: "second")
    }
    private func add(_ path: String, text: String) {
        let bytes = Data(text.utf8); data[path] = bytes
        values[path] = RemoteEntry(path: path, isDirectory: false, size: Int64(bytes.count), version: path)
    }
    func stat(path: String, cancellation: TransferCancellation) throws -> RemoteEntry? { try check(cancellation); return values[path] }
    func list(path: String, cancellation: TransferCancellation) throws -> [RemoteEntry] {
        try check(cancellation)
        return values.values.filter { $0.path != path && RemotePath.parent($0.path) == path }.sorted { $0.path < $1.path }
    }
    func searchDownload(path: String, to: URL, maximumBytes: Int64, cancellation: TransferCancellation,
                        progress: @escaping (NetworkProgress) -> Void) throws {
        downloads += 1
        while waitForCancellation { try check(cancellation); Thread.sleep(forTimeInterval: 0.01) }
        try check(cancellation)
        guard let bytes = data[path], bytes.count <= maximumBytes else { throw NetworkError.limitExceeded("Fixture ceiling") }
        try bytes.write(to: to)
        progress(NetworkProgress(path: path, completedBytes: Int64(bytes.count), totalBytes: Int64(bytes.count)))
    }
    func download(path: String, to: URL, resumeOffset: Int64, cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws {
        try searchDownload(path: path, to: to, maximumBytes: Int64.max, cancellation: cancellation, progress: progress)
    }
    func upload(from: URL, to: String, cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws { throw NetworkError.unsupported("Fixture upload disabled") }
    func rename(from: String, to: String, replace: Bool, cancellation: TransferCancellation) throws { throw NetworkError.unsupported("Fixture rename disabled") }
    func remove(path: String, isDirectory: Bool, cancellation: TransferCancellation) throws {
        try check(cancellation)
        guard allowsRemoval, path != "/", let entry = values[path], entry.isDirectory == isDirectory else { throw NetworkError.unsupported("Fixture deletion disabled or invalid") }
        if isDirectory, values.keys.contains(where: { $0 != path && RemotePath.parent($0) == path }) { throw NetworkError.io("Fixture directory not empty") }
        values.removeValue(forKey: path); data.removeValue(forKey: path)
    }
    func makeDirectory(path: String, cancellation: TransferCancellation) throws { throw NetworkError.unsupported("Fixture mkdir disabled") }
    private func check(_ token: TransferCancellation) throws { if token.isCancelled { throw NetworkError.cancelled } }
}
