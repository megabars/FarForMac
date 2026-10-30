import Foundation
import CNetwork

struct WebRemoteError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// RFC 3659 machine-readable listings. Credentials stay in this process; FTPS
/// requires TLS on both connections and normal certificate verification.
public final class FTPRemoteProvider: RemoteProvider {
    public let connection: NetworkConnection
    private let password: String?
    public init(connection: NetworkConnection, password: String?) {
        self.connection = connection; self.password = password
    }

    public func list(path: String, cancellation: TransferCancellation) throws -> [RemoteEntry] {
        let data = try perform(path: path, directory: true, operation: 0, cancellation: cancellation)
        return try Self.parseListing(data, path: path)
    }

    public func stat(path: String, cancellation: TransferCancellation) throws -> RemoteEntry? {
        let clean = try webRemotePath(path)
        if clean == "/" {
            _ = try list(path: clean, cancellation: cancellation)
            return RemoteEntry(path: clean, isDirectory: true, isSymbolicLink: false, size: 0, modified: nil, version: nil)
        }
        let parent = (clean as NSString).deletingLastPathComponent
        return try list(path: parent.isEmpty ? "/" : parent, cancellation: cancellation).first { $0.path == clean }
    }

    public func download(path: String, to: URL, resumeOffset: Int64, cancellation: TransferCancellation,
                         progress: @escaping (NetworkProgress) -> Void) throws {
        try webRemoteCheck(cancellation)
        try connection.validate()
        guard resumeOffset >= 0 else { throw WebRemoteError("Invalid download offset.") }
        if !FileManager.default.fileExists(atPath: to.path) {
            guard resumeOffset == 0, FileManager.default.createFile(atPath: to.path, contents: nil) else {
                throw WebRemoteError("The partial download is missing.")
            }
        }
        let file = try FileHandle(forWritingTo: to)
        defer { try? file.close() }
        guard try file.seekToEnd() == UInt64(resumeOffset) || resumeOffset == 0 else {
            throw WebRemoteError("The partial download size changed.")
        }
        if resumeOffset == 0 { try file.truncate(atOffset: 0) }
        try file.seek(toOffset: UInt64(resumeOffset))
        _ = try perform(path: path, operation: 1, offset: resumeOffset, cancellation: cancellation,
                        progress: progress, file: file)
    }

    public func upload(from: URL, to: String, cancellation: TransferCancellation,
                       progress: @escaping (NetworkProgress) -> Void) throws {
        _ = try perform(path: to, operation: 2, localPath: from.path, cancellation: cancellation, progress: progress)
    }

    public func rename(from: String, to: String, replace: Bool, cancellation: TransferCancellation) throws {
        // FTP has no conditional RNTO. This check prevents known conflicts but
        // cannot exclude another client creating the destination before RNTO.
        if !replace, try stat(path: to, cancellation: cancellation) != nil {
            throw WebRemoteError("The FTP rename destination already exists.")
        }
        _ = try perform(path: "/", directory: true, operation: 3,
                        commands: ["RNFR \(try webRemotePath(from))", "RNTO \(try webRemotePath(to))"], cancellation: cancellation)
    }

    public func remove(path: String, isDirectory: Bool, cancellation: TransferCancellation) throws {
        let clean = try webRemotePath(path)
        guard clean != "/" else { throw WebRemoteError("The connection root cannot be removed.") }
        _ = try perform(path: "/", directory: true, operation: 3,
                        commands: ["\(isDirectory ? "RMD" : "DELE") \(clean)"], cancellation: cancellation)
    }

    public func makeDirectory(path: String, cancellation: TransferCancellation) throws {
        _ = try perform(path: "/", directory: true, operation: 3,
                        commands: ["MKD \(try webRemotePath(path))"], cancellation: cancellation)
    }

    private func perform(path: String, directory: Bool = false, operation: Int32, localPath: String? = nil,
                         offset: Int64 = 0, commands: [String] = [], cancellation: TransferCancellation,
                         progress: @escaping (NetworkProgress) -> Void = { _ in }, file: FileHandle? = nil) throws -> Data {
        try webRemoteCheck(cancellation)
        try connection.validate()
        guard connection.kind == .ftp || connection.kind == .ftps else { throw WebRemoteError("This connection is not FTP or FTPS.") }
        guard !(password ?? "").contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) else {
            throw WebRemoteError("FTP passwords cannot contain control line separators.")
        }
        let clean = try webRemotePath(path)
        var components = URLComponents()
        components.scheme = "ftp"; components.host = connection.host; components.port = connection.port
        // %2F makes the FTP path absolute rather than relative to the login directory.
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "%?#"))
        components.percentEncodedPath = "/%2F" + String(clean.dropFirst()).addingPercentEncoding(withAllowedCharacters: allowed)! + (directory ? "/" : "")
        guard let url = components.url else { throw WebRemoteError("Invalid FTP server address.") }
        let state = FTPRequestState(path: clean, cancellation: cancellation, progress: progress, file: file, offset: offset)
        let context = Unmanaged.passUnretained(state).toOpaque()
        var response: Int = 0
        var error = [CChar](repeating: 0, count: 1024)
        let result = far_ftp_perform(url.absoluteString, connection.username, password, connection.kind == .ftps ? 1 : 0,
                                     max(1, min(connection.timeoutSeconds, 86_400)), operation, localPath, offset,
                                     commands.first, commands.count > 1 ? commands[1] : nil,
                                     { bytes, count, context in
                                         guard let bytes, let context else { return 0 }
                                         let state = Unmanaged<FTPRequestState>.fromOpaque(context).takeUnretainedValue()
                                         if state.cancellation.isCancelled { return 0 }
                                         let chunk = Data(bytes: bytes, count: count)
                                         do {
                                             if let file = state.file { try file.write(contentsOf: chunk) }
                                             else {
                                                 guard state.data.count + count <= 32 * 1024 * 1024 else { throw WebRemoteError("FTP listing exceeds the 32 MB limit.") }
                                                 state.data.append(chunk)
                                             }
                                             return count
                                         } catch { state.error = error; return 0 }
                                     }, { completed, total, context in
                                         guard let context else { return 1 }
                                         let state = Unmanaged<FTPRequestState>.fromOpaque(context).takeUnretainedValue()
                                         if state.cancellation.isCancelled { return 1 }
                                         state.progress(NetworkProgress(path: state.path, completedBytes: state.offset + completed,
                                                                        totalBytes: total > 0 ? state.offset + total : 0))
                                         return 0
                                     }, context, &response, &error, error.count)
        try webRemoteCheck(cancellation)
        if let error = state.error { throw error }
        guard result == 0 else {
            if operation == 0 && [500, 501, 502, 504].contains(response) {
                throw WebRemoteError("The FTP server does not support MLSD machine-readable listings (\(response)).")
            }
            var detail = String(cString: error)
            if let password, !password.isEmpty { detail = detail.replacingOccurrences(of: password, with: "••••") }
            let action = ["MLSD", "download", "upload", "command"][Int(operation)]
            throw WebRemoteError("FTP \(action) \(clean) failed (\(response), transport \(result)): \(detail)")
        }
        return state.data
    }

    static func parseListing(_ data: Data, path: String) throws -> [RemoteEntry] {
        guard let text = String(data: data, encoding: .utf8) else { throw WebRemoteError("The FTP server returned a listing that is not UTF-8.") }
        let base = try webRemotePath(path)
        var entries: [RemoteEntry] = []
        var names = Set<String>()
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0); date.dateFormat = "yyyyMMddHHmmss"
        for raw in text.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.isEmpty { continue }
            guard let split = line.firstIndex(of: " ") else { throw WebRemoteError("Malformed MLSD listing.") }
            let name = String(line[line.index(after: split)...])
            var facts: [String: String] = [:]
            for fact in line[..<split].split(separator: ";") {
                guard let equals = fact.firstIndex(of: "=") else { throw WebRemoteError("Malformed MLSD fact.") }
                facts[String(fact[..<equals]).lowercased()] = String(fact[fact.index(after: equals)...])
            }
            guard let type = facts["type"]?.lowercased() else { throw WebRemoteError("MLSD listing has no entry type.") }
            if type == "cdir" || type == "pdir" { continue }
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\r"), !name.contains("\0") else { throw WebRemoteError("Unsafe filename in FTP listing.") }
            guard names.insert(name).inserted else { throw WebRemoteError("Duplicate filename in FTP listing.") }
            let link = type.hasPrefix("os.unix=slink") || type.hasPrefix("os.unix=symlink")
            guard type == "file" || type == "dir" || link else { throw WebRemoteError("Unsupported MLSD entry type: \(type).") }
            let size = facts["size"].flatMap(Int64.init) ?? 0
            guard size >= 0 else { throw WebRemoteError("Invalid MLSD file size.") }
            let modified = facts["modify"].flatMap { date.date(from: String($0.prefix(14))) }
            let version = [facts["unique"], facts["modify"], facts["size"]].map { $0 ?? "" }.joined(separator: ":")
            entries.append(RemoteEntry(path: (base == "/" ? "" : base) + "/" + name, isDirectory: type == "dir", isSymbolicLink: link,
                                       size: size, modified: modified, version: version == "::" ? nil : version))
        }
        return entries
    }
}

private final class FTPRequestState {
    let path: String
    let cancellation: TransferCancellation
    let progress: (NetworkProgress) -> Void
    let file: FileHandle?
    let offset: Int64
    var data = Data()
    var error: Error?
    init(path: String, cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void, file: FileHandle?, offset: Int64) {
        self.path = path; self.cancellation = cancellation; self.progress = progress; self.file = file; self.offset = offset
    }
}

func webRemoteCheck(_ cancellation: TransferCancellation) throws {
    if cancellation.isCancelled { throw NetworkError.cancelled }
}

func webRemotePath(_ path: String) throws -> String {
    try RemotePath.validate(path)
}
