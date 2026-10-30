import Foundation

/// WebDAV with validated TLS, no redirects, bounded XML, and streaming transfers.
public final class WebRemoteProvider: RemoteConditionalDownloadProvider {
    public let connection: NetworkConnection
    private let password: String?
    public init(connection: NetworkConnection, password: String?) {
        self.connection = connection; self.password = password
    }

    public func list(path: String, cancellation: TransferCancellation) throws -> [RemoteEntry] {
        let clean = try webRemotePath(path)
        let entries = try properties(path: clean, depth: "1", cancellation: cancellation)
        guard entries.allSatisfy({ $0.path == clean || RemotePath.parent($0.path) == clean }) else {
            throw WebRemoteError("WebDAV returned a resource outside the requested directory.")
        }
        return entries.filter { $0.path != clean }
    }

    public func stat(path: String, cancellation: TransferCancellation) throws -> RemoteEntry? {
        let clean = try webRemotePath(path)
        do {
            let values = try properties(path: clean, depth: "0", cancellation: cancellation)
            guard let entry = values.first(where: { $0.path == clean }) else { throw WebRemoteError("WebDAV did not return the requested resource.") }
            return entry
        } catch let error as DAVStatusError where [301, 302, 307, 308].contains(error.code) {
            // Probe the same path's collection form without following Location.
            // No credentials are ever forwarded to a redirect target.
            return try properties(path: clean, depth: "0", collectionURL: true, cancellation: cancellation).first { $0.path == clean }
        } catch let error as DAVStatusError where error.code == 404 { return nil }
    }

    public func download(path: String, to: URL, resumeOffset: Int64, cancellation: TransferCancellation,
                         progress: @escaping (NetworkProgress) -> Void) throws {
        try download(path: path, to: to, resumeOffset: resumeOffset, expectedVersion: nil, cancellation: cancellation, progress: progress)
    }

    /// Retrieves bytes from one strong entity version. A failed precondition or
    /// an ignored range is rejected before the existing partial file is changed.
    public func conditionalDownload(path: String, to: URL, resumeOffset: Int64, expectedVersion: String,
                                    cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws {
        try validateStrongETag(expectedVersion)
        try download(path: path, to: to, resumeOffset: resumeOffset, expectedVersion: expectedVersion,
                     cancellation: cancellation, progress: progress)
    }

    private func download(path: String, to: URL, resumeOffset: Int64, expectedVersion: String?, cancellation: TransferCancellation,
                          progress: @escaping (NetworkProgress) -> Void) throws {
        try webRemoteCheck(cancellation)
        guard resumeOffset >= 0 else { throw WebRemoteError("Invalid download offset.") }
        var headers: [String: String] = ["Accept-Encoding": "identity"]
        if let expectedVersion { headers["If-Match"] = expectedVersion }
        if resumeOffset > 0 { headers["Range"] = "bytes=\(resumeOffset)-" }
        if !FileManager.default.fileExists(atPath: to.path) {
            guard resumeOffset == 0, FileManager.default.createFile(atPath: to.path, contents: nil) else { throw WebRemoteError("The partial download is missing.") }
        }
        let file = try FileHandle(forWritingTo: to)
        defer { try? file.close() }
        guard try file.seekToEnd() == UInt64(resumeOffset) || resumeOffset == 0 else { throw WebRemoteError("The partial download size changed.") }
        // Truncation waits until the server's status and range have been validated.
        _ = try request("GET", path: path, headers: headers, file: file, offset: resumeOffset, expectedETag: expectedVersion,
                        cancellation: cancellation, progress: progress)
    }

    public func upload(from: URL, to: String, cancellation: TransferCancellation,
                       progress: @escaping (NetworkProgress) -> Void) throws {
        _ = try request("PUT", path: to, headers: ["Content-Type": "application/octet-stream"], upload: from,
                        cancellation: cancellation, progress: progress)
    }

    /// Saves an edited resource only while its strong entity tag still matches.
    /// A 412 response leaves the server's current resource untouched.
    public func conditionalUpload(from: URL, to: String, expectedVersion: String, cancellation: TransferCancellation,
                                  progress: @escaping (NetworkProgress) -> Void) throws {
        try validateStrongETag(expectedVersion)
        _ = try request("PUT", path: to, headers: ["Content-Type": "application/octet-stream", "If-Match": expectedVersion], upload: from,
                        cancellation: cancellation, progress: progress)
    }

    private func validateStrongETag(_ expectedVersion: String) throws {
        guard expectedVersion.hasPrefix("\""), expectedVersion.hasSuffix("\""), expectedVersion.count >= 2,
              !expectedVersion.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !expectedVersion.dropFirst().dropLast().contains("\"") else {
            throw NetworkError.unsupported("WebDAV conditional transfers require a strong ETag from the server.")
        }
    }

    public func rename(from: String, to: String, replace: Bool, cancellation: TransferCancellation) throws {
        _ = try request("MOVE", path: from, headers: ["Destination": try url(to).absoluteString, "Overwrite": replace ? "T" : "F"],
                        cancellation: cancellation)
    }

    public func remove(path: String, isDirectory: Bool, cancellation: TransferCancellation) throws {
        guard try webRemotePath(path) != "/" else { throw WebRemoteError("The connection root cannot be removed.") }
        _ = try request("DELETE", path: path, cancellation: cancellation)
    }

    public func makeDirectory(path: String, cancellation: TransferCancellation) throws {
        _ = try request("MKCOL", path: path, cancellation: cancellation)
    }

    private func properties(path: String, depth: String, collectionURL: Bool = false, cancellation: TransferCancellation) throws -> [RemoteEntry] {
        let body = Data("""
        <?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:getetag/></d:prop></d:propfind>
        """.utf8)
        let response = try request("PROPFIND", path: path, headers: ["Depth": depth, "Content-Type": "application/xml; charset=utf-8"],
                                   body: body, collectionURL: collectionURL || depth == "1", cancellation: cancellation)
        let parser = DAVPropertiesParser(base: try url(path))
        return try parser.parse(response.data)
    }

    private func url(_ path: String) throws -> URL {
        try connection.validate()
        guard connection.kind == .webdav || connection.kind == .webdavs else { throw WebRemoteError("This connection is not WebDAV.") }
        var components = URLComponents()
        components.scheme = connection.kind == .webdavs ? "https" : "http"
        components.host = connection.host; components.port = connection.port
        components.path = try webRemotePath(path)
        guard let url = components.url else { throw WebRemoteError("Invalid WebDAV server address.") }
        return url
    }

    private func request(_ method: String, path: String, headers: [String: String] = [:], body: Data? = nil,
                         upload: URL? = nil, file: FileHandle? = nil, offset: Int64 = 0,
                         expectedETag: String? = nil,
                         collectionURL: Bool = false,
                         cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void = { _ in }) throws -> DAVResponse {
        try webRemoteCheck(cancellation)
        guard !connection.username.contains(":"), !(password ?? "").contains("\0") else {
            throw WebRemoteError("Invalid HTTP authentication credentials.")
        }
        let timeout = max(1, min(connection.timeoutSeconds, 86_400))
        var target = try url(path)
        if collectionURL && !target.path.hasSuffix("/") { target.appendPathComponent("") }
        var request = URLRequest(url: target, timeoutInterval: timeout)
        request.httpMethod = method; request.httpBody = body
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let credentials = Data("\(connection.username):\(password ?? "")".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout; config.timeoutIntervalForResource = timeout
        let delegate = DAVRequestDelegate(method: method, path: path, file: file, offset: offset, expectedETag: expectedETag, progress: progress)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task: URLSessionTask
        if let upload { task = session.uploadTask(with: request, fromFile: upload) }
        else { task = session.dataTask(with: request) }
        task.resume()
        while delegate.done.wait(timeout: .now() + 0.1) == .timedOut {
            if cancellation.isCancelled { task.cancel() }
        }
        try webRemoteCheck(cancellation)
        if let error = delegate.error { throw error }
        guard let status = delegate.response else { throw WebRemoteError("The server returned no HTTP response.") }
        guard method == "PROPFIND" ? status.statusCode == 207 : (200..<300).contains(status.statusCode) && status.statusCode != 207 else {
            throw DAVStatusError(code: status.statusCode)
        }
        return DAVResponse(data: delegate.data, response: status)
    }
}

private struct DAVResponse { let data: Data; let response: HTTPURLResponse }
private struct DAVStatusError: LocalizedError {
    let code: Int
    var errorDescription: String? {
        code == 207 ? "WebDAV reports a partial operation; inspect the remote directory before retrying." : "WebDAV operation failed (HTTP \(code))."
    }
}

private final class DAVRequestDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    let method: String
    let path: String
    let file: FileHandle?
    let offset: Int64
    let expectedETag: String?
    let progress: (NetworkProgress) -> Void
    var response: HTTPURLResponse?
    var error: Error?
    var data = Data()
    var received: Int64 = 0
    var expectedDownloadLength: Int64?
    init(method: String, path: String, file: FileHandle?, offset: Int64, expectedETag: String?, progress: @escaping (NetworkProgress) -> Void) {
        self.method = method; self.path = path; self.file = file; self.offset = offset; self.expectedETag = expectedETag; self.progress = progress
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            error = WebRemoteError("Invalid HTTP response."); completionHandler(.cancel); return
        }
        self.response = http
        if let file {
            if let expectedETag {
                if http.statusCode == 412 || http.value(forHTTPHeaderField: "ETag").map({ $0 != expectedETag }) == true {
                    error = NetworkError.changedSource; completionHandler(.cancel); return
                }
            }
            guard http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else {
                error = WebRemoteError("The server did not provide unencoded download bytes."); completionHandler(.cancel); return
            }
            let valid: Bool
            if offset > 0 {
                let range = http.value(forHTTPHeaderField: "Content-Range") ?? ""
                let pieces = range.replacingOccurrences(of: "bytes ", with: "").split(separator: "/")
                let bounds = pieces.first?.split(separator: "-") ?? []
                if http.statusCode == 206, range.hasPrefix("bytes "), pieces.count == 2, bounds.count == 2,
                   let start = Int64(bounds[0]), let end = Int64(bounds[1]), let total = Int64(pieces[1]),
                   start == offset, end >= start, total > end {
                    expectedDownloadLength = end - start + 1
                    valid = http.expectedContentLength < 0 || http.expectedContentLength == expectedDownloadLength
                } else { valid = false }
            } else {
                valid = http.statusCode == 200
                if http.expectedContentLength >= 0 { expectedDownloadLength = http.expectedContentLength }
            }
            guard valid else {
                error = WebRemoteError("The server did not return the requested download range (HTTP \(http.statusCode)).")
                completionHandler(.cancel); return
            }
            do {
                if offset == 0 { try file.truncate(atOffset: 0) }
                try file.seek(toOffset: UInt64(offset))
            } catch { self.error = error; completionHandler(.cancel); return }
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            if let file { try file.write(contentsOf: data) }
            else {
                guard self.data.count + data.count <= 32 * 1024 * 1024 else { throw WebRemoteError("WebDAV response exceeds the 32 MB limit.") }
                self.data.append(data)
            }
            received += Int64(data.count)
            progress(NetworkProgress(path: path, completedBytes: offset + received,
                                     totalBytes: (response?.expectedContentLength ?? -1) >= 0 ? offset + (response?.expectedContentLength ?? 0) : 0))
        } catch { self.error = error; dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress(NetworkProgress(path: path, completedBytes: totalBytesSent, totalBytes: max(0, totalBytesExpectedToSend)))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if self.error == nil { self.error = error }
        if self.error == nil, file != nil, let expectedDownloadLength, received != expectedDownloadLength {
            self.error = WebRemoteError("The downloaded response length does not match the requested range.")
        }
        done.signal()
    }
}

/// Parse only successful DAV properties, reject XML entities and foreign hrefs.
final class DAVPropertiesParser: NSObject, XMLParserDelegate {
    let base: URL
    private var entries: [RemoteEntry] = []
    private var failure: Error?
    private var stack: [String] = []
    private var text = ""
    private var href = ""
    private var status = ""
    private var responseStatus = ""
    private var props: [String: String] = [:]
    private var successful: [String: String] = [:]
    private var collection = false
    private var multistatus = false
    private var paths = Set<String>()
    init(base: URL) { self.base = base }
    func parse(_ data: Data) throws -> [RemoteEntry] {
        // XMLParser does not resolve external entities, and DTDs are not needed by DAV.
        guard let text = String(data: data, encoding: .utf8), !text.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !text.localizedCaseInsensitiveContains("<!ENTITY") else { throw WebRemoteError("Unsafe or unsupported WebDAV XML.") }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = self
        guard parser.parse(), failure == nil else { throw failure ?? parser.parserError ?? WebRemoteError("Malformed WebDAV response.") }
        guard stack.isEmpty, multistatus else { throw WebRemoteError("Incomplete WebDAV response.") }
        return entries
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let name = namespaceURI == "DAV:" ? elementName : "unknown"
        if stack.isEmpty { multistatus = name == "multistatus" }
        stack.append(name); text = ""
        if name == "response" { href = ""; responseStatus = ""; successful = [:] }
        if name == "propstat" { props = [:]; status = ""; collection = false }
        if name == "collection", stack.contains("resourcetype") { collection = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        guard let name = stack.last else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "href", stack == ["multistatus", "response", "href"] { href = value }
        if name == "status" {
            if stack.contains("propstat") { status = value } else { responseStatus = value }
        }
        if ["getcontentlength", "getlastmodified", "getetag"].contains(name) { props[name] = value }
        if name == "resourcetype" { props[name] = collection ? "collection" : "file" }
        if name == "propstat", status.split(separator: " ").dropFirst().first == "200" { successful.merge(props) { _, new in new } }
        if name == "response" {
            do {
                guard responseStatus.isEmpty || responseStatus.split(separator: " ").dropFirst().first == "200" else { throw WebRemoteError("WebDAV resource failed: \(responseStatus).") }
                guard let type = successful["resourcetype"], let target = URL(string: href, relativeTo: base)?.absoluteURL,
                      target.scheme == base.scheme, target.host == base.host, target.port == base.port,
                      target.user == nil, target.password == nil, target.query == nil, target.fragment == nil else {
                    throw WebRemoteError("WebDAV returned invalid properties or a foreign resource address.")
                }
                let clean = try webRemotePath(target.path)
                guard paths.insert(clean).inserted else { throw WebRemoteError("Duplicate resource in WebDAV listing.") }
                let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0); date.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
                let size = successful["getcontentlength"].flatMap(Int64.init) ?? 0
                guard size >= 0 else { throw WebRemoteError("Invalid WebDAV content length.") }
                entries.append(RemoteEntry(path: clean, isDirectory: type == "collection", isSymbolicLink: false, size: size,
                                           modified: successful["getlastmodified"].flatMap { date.date(from: $0) }, version: successful["getetag"]))
            } catch { failure = error; parser.abortParsing() }
        }
        stack.removeLast(); text = ""
    }
}
