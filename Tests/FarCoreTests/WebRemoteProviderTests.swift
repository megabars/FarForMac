import Foundation
import Testing
@testable import FarCore

@Suite
final class WebRemoteProviderTests {
    @Test func testMLSDUsesFactsAndPreservesNames() throws {
        let entries = try FTPRemoteProvider.parseListing(Data("type=cdir; .\r\ntype=file;size=42;modify=20261030123456;unique=abc; leading space.txt\r\ntype=dir; folder\r\n".utf8), path: "/base")
        #expect(entries.map(\.path) == ["/base/leading space.txt", "/base/folder"])
        #expect(entries[0].size == 42)
        #expect(entries[0].modified != nil)
        #expect(entries[1].isDirectory)
        webExpectThrows(try FTPRemoteProvider.parseListing(Data("drwx------ 1 user group 42 Oct 30 folder\n".utf8), path: "/"))
        webExpectThrows(try FTPRemoteProvider.parseListing(Data("type=file; ../escape\n".utf8), path: "/"))
    }

    @Test func testDAVRejectsForeignOriginsAndEntities() throws {
        let parser = DAVPropertiesParser(base: URL(string: "https://example.com:443/")!)
        let foreign = "<d:multistatus xmlns:d='DAV:'><d:response><d:href>https://attacker.example/file</d:href><d:propstat><d:prop><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>"
        webExpectThrows(try parser.parse(Data(foreign.utf8)))
        webExpectThrows(try DAVPropertiesParser(base: URL(string: "https://example.com/")!).parse(Data("<!DOCTYPE x [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><x>&x;</x>".utf8)))
        webExpectThrows(try DAVPropertiesParser(base: URL(string: "https://example.com/")!).parse(Data("<html/>".utf8)))
    }

    @Test func testLoopbackDAVOperationsResumeAndSecurity() throws {
        let fixture = try WebRemoteFixture()
        defer { fixture.stop() }
        let provider = WebRemoteProvider(connection: fixture.connection(.webdav), password: "memory-only-secret")
        try exercise(provider, fixture: fixture, prefix: "dav")
        let destination = fixture.root.appendingPathComponent("redirect-output")
        try Data("untouched".utf8).write(to: destination)
        webExpectThrows(try provider.download(path: "/redirect", to: destination, resumeOffset: 0, cancellation: TransferCancellation(), progress: { _ in }))
        #expect(try Data(contentsOf: destination) == Data("untouched".utf8))
        #expect(!(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("credential-leak").path)))
        webExpectThrows(try provider.remove(path: "/partial", isDirectory: true, cancellation: TransferCancellation()))
        let bad = WebRemoteProvider(connection: fixture.connection(.webdav), password: "bad-password")
        webExpectThrows(try bad.list(path: "/", cancellation: TransferCancellation()))
        let edit = fixture.root.appendingPathComponent("edit")
        try Data("edited".utf8).write(to: edit)
        webExpectThrows(try provider.conditionalUpload(from: edit, to: "/hello space.txt", expectedVersion: "\"changed\"", cancellation: TransferCancellation(), progress: { _ in }))
        let unchanged = fixture.root.appendingPathComponent("unchanged")
        try provider.download(path: "/hello space.txt", to: unchanged, resumeOffset: 0, cancellation: TransferCancellation(), progress: { _ in })
        #expect(try Data(contentsOf: unchanged) == Data("hello remote world".utf8))
        webExpectThrows(try provider.conditionalUpload(from: edit, to: "/hello space.txt", expectedVersion: "W/\"v1\"", cancellation: TransferCancellation(), progress: { _ in }))
        try provider.conditionalUpload(from: edit, to: "/hello space.txt", expectedVersion: "\"v1\"", cancellation: TransferCancellation(), progress: { _ in })
        #expect(try provider.stat(path: "/hello space.txt", cancellation: TransferCancellation())?.size == 6)
    }

    @Test func testLoopbackFTPAndRequiredTLS() throws {
        let fixture = try WebRemoteFixture()
        defer { fixture.stop() }
        let provider = FTPRemoteProvider(connection: fixture.connection(.ftp), password: "memory-only-secret")
        try exercise(provider, fixture: fixture, prefix: "ftp")
        webExpectThrows(try provider.list(path: "/unsupported", cancellation: TransferCancellation())) { error in
            #expect(error.localizedDescription.contains("MLSD"))
        }
        var secure = fixture.connection(.ftps); secure.timeoutSeconds = 2
        let tls = FTPRemoteProvider(connection: secure, password: "memory-only-secret")
        webExpectThrows(try tls.list(path: "/", cancellation: TransferCancellation()))
    }

    @Test func testDAVCancellationAndTimeout() throws {
        let fixture = try WebRemoteFixture()
        defer { fixture.stop() }
        var connection = fixture.connection(.webdav); connection.timeoutSeconds = 1
        let provider = WebRemoteProvider(connection: connection, password: "memory-only-secret")
        let destination = fixture.root.appendingPathComponent("slow-output")
        let start = Date()
        webExpectThrows(try provider.download(path: "/slow", to: destination, resumeOffset: 0, cancellation: TransferCancellation(), progress: { _ in }))
        #expect(Date().timeIntervalSince(start) < 2.5)
        let cancellation = TransferCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { cancellation.cancel() }
        let cancelledStart = Date()
        webExpectThrows(try provider.download(path: "/slow", to: destination, resumeOffset: 0, cancellation: cancellation, progress: { _ in }))
        #expect(Date().timeIntervalSince(cancelledStart) < 1)
    }

    @Test func testUntrustedCertificatesRejectedBeforeCredentials() throws {
        let fixture = try WebRemoteFixture(tls: true)
        defer { fixture.stop() }
        let web = WebRemoteProvider(connection: fixture.connection(.webdavs), password: "memory-only-secret")
        webExpectThrows(try web.list(path: "/", cancellation: TransferCancellation()))
        let ftp = FTPRemoteProvider(connection: fixture.connection(.ftps), password: "memory-only-secret")
        webExpectThrows(try ftp.list(path: "/", cancellation: TransferCancellation()))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("tls-credentials-sent").path))
    }

    @Test func testConditionalDownloadResumesInterruptedVersionAndProtectsPartial() throws {
        let fixture = try WebRemoteFixture()
        defer { fixture.stop() }
        let provider = WebRemoteProvider(connection: fixture.connection(.webdav), password: "memory-only-secret")
        let token = TransferCancellation()
        let partial = fixture.root.appendingPathComponent("conditional-partial")
        let prefix = Data(repeating: 65, count: 65536)
        let complete = Data(repeating: 65, count: 131072)
        webExpectThrows(try provider.conditionalDownload(path: "/interrupted", to: partial, resumeOffset: 0,
                                                       expectedVersion: "\"v1\"", cancellation: token, progress: { _ in }))
        #expect(try Data(contentsOf: partial) == prefix)
        try provider.conditionalDownload(path: "/interrupted", to: partial, resumeOffset: 65536,
                                         expectedVersion: "\"v1\"", cancellation: token, progress: { _ in })
        #expect(try Data(contentsOf: partial) == complete)

        // The resource changes after an earlier interruption. Both fresh and
        // resumed failed preconditions must preserve the owned partial bytes.
        try prefix.write(to: partial)
        let changed = fixture.root.appendingPathComponent("changed-source")
        try Data("changed on server".utf8).write(to: changed)
        try provider.upload(from: changed, to: "/interrupted", cancellation: token, progress: { _ in })
        for offset in [Int64(0), 65536] {
            webExpectThrows(try provider.conditionalDownload(path: "/interrupted", to: partial, resumeOffset: offset,
                                                           expectedVersion: "\"v1\"", cancellation: token, progress: { _ in }))
            #expect(try Data(contentsOf: partial) == prefix)
        }
        try Data("hello ".utf8).write(to: partial)
        for (path, version) in [("/ignore-range", "\"v1\""), ("/wrong-response-etag", "\"v1\""), ("/hello space.txt", "W/\"v1\"")] {
            webExpectThrows(try provider.conditionalDownload(path: path, to: partial, resumeOffset: 6,
                                                           expectedVersion: version, cancellation: token, progress: { _ in }))
            #expect(try Data(contentsOf: partial) == Data("hello ".utf8))
        }
    }

    private func exercise(_ provider: RemoteProvider, fixture: WebRemoteFixture, prefix: String) throws {
        let cancellation = TransferCancellation()
        let entries = try provider.list(path: "/", cancellation: cancellation)
        #expect(entries.contains { $0.path == "/hello space.txt" && $0.size == 18 })
        #expect(try provider.stat(path: "/missing", cancellation: cancellation) == nil)
        let partial = fixture.root.appendingPathComponent("\(prefix)-download")
        try Data("hello ".utf8).write(to: partial)
        var progress: [Int64] = []
        try provider.download(path: "/hello space.txt", to: partial, resumeOffset: 6, cancellation: cancellation, progress: { progress.append($0.completedBytes) })
        #expect(try Data(contentsOf: partial) == Data("hello remote world".utf8))
        #expect(progress.contains { $0 >= 18 })
        let upload = fixture.root.appendingPathComponent("\(prefix)-source")
        try Data("uploaded bytes".utf8).write(to: upload)
        try provider.makeDirectory(path: "/\(prefix)-folder", cancellation: cancellation)
        try provider.upload(from: upload, to: "/\(prefix)-folder/new file", cancellation: cancellation, progress: { _ in })
        #expect(try provider.stat(path: "/\(prefix)-folder/new file", cancellation: cancellation)?.size == 14)
        try provider.rename(from: "/\(prefix)-folder/new file", to: "/\(prefix)-folder/renamed", replace: false, cancellation: cancellation)
        webExpectThrows(try provider.rename(from: "/hello space.txt", to: "/\(prefix)-folder/renamed", replace: false, cancellation: cancellation))
        #expect(try provider.stat(path: "/hello space.txt", cancellation: cancellation) != nil)
        try provider.remove(path: "/\(prefix)-folder/renamed", isDirectory: false, cancellation: cancellation)
        try provider.remove(path: "/\(prefix)-folder", isDirectory: true, cancellation: cancellation)
        let stopped = TransferCancellation(); stopped.cancel()
        webExpectThrows(try provider.list(path: "/", cancellation: stopped))
    }
}

private final class WebRemoteFixture {
    let root: URL
    let process: Process
    let ports: [String: Int]
    init(tls: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("far-web-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("NetworkFixtures/web_remote_fixture.py")
        process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, root.path] + (tls ? ["tls"] : [])
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let ready = root.appendingPathComponent("ports.json")
        let deadline = Date().addingTimeInterval(5)
        var values: [String: Int]?
        while Date() < deadline && process.isRunning {
            if let data = try? Data(contentsOf: ready), let result = try? JSONDecoder().decode([String: Int].self, from: data) { values = result; break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard let values else { process.terminate(); throw NSError(domain: "WebRemoteFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Local fixture did not start."]) }
        ports = values
    }
    func connection(_ kind: NetworkProtocol) -> NetworkConnection {
        let key = kind == .ftps && ports["ftps"] != nil ? "ftps" : kind == .webdavs ? "https" : kind == .ftp || kind == .ftps ? "ftp" : "http"
        return NetworkConnection(kind: kind, host: "127.0.0.1", port: ports[key]!, username: "tester", timeoutSeconds: 3)
    }
    func stop() {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: root)
    }
}

private func webExpectThrows<T>(_ expression: @autoclosure () throws -> T, inspect: ((Error) -> Void)? = nil) {
    do {
        _ = try expression()
        Issue.record("Expected the remote operation to fail")
    } catch { inspect?(error) }
}
