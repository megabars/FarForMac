import Foundation
import Testing
@testable import FarCore

@Suite(.serialized)
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
        try Data("untouched".utf8).write(to: destination)
        webExpectThrows(try provider.download(path: "/slow", to: destination, resumeOffset: 0, cancellation: TransferCancellation(), progress: { _ in })) { error in
            // URLSession reports its timeout directly; verify the cause rather
            // than measuring scheduling delays on a shared CI machine.
            let failure = error as NSError
            #expect(failure.domain == NSURLErrorDomain)
            #expect(failure.code == NSURLErrorTimedOut)
        }
        #expect(try Data(contentsOf: destination) == Data("untouched".utf8))
        // Give cancellation its own timeout so a transport timeout cannot satisfy
        // this assertion on a busy runner. Existing destination bytes must survive.
        connection.timeoutSeconds = 5
        let cancellable = WebRemoteProvider(connection: connection, password: "memory-only-secret")
        try Data("untouched".utf8).write(to: destination)
        let cancellation = TransferCancellation()
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.15)
            cancellation.cancel()
        }
        webExpectThrows(try cancellable.download(path: "/slow", to: destination, resumeOffset: 0, cancellation: cancellation, progress: { _ in })) { error in
            #expect(error as? NetworkError == .cancelled)
        }
        #expect(try Data(contentsOf: destination) == Data("untouched".utf8))
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

    @Test func searchDownloadEnforcesDAVAndFTPByteCeilingsBeforeWriting() throws {
        let fixture = try WebRemoteFixture(); defer { fixture.stop() }
        let providers: [RemoteSearchDownloadProvider] = [
            WebRemoteProvider(connection: fixture.connection(.webdav), password: "memory-only-secret"),
            FTPRemoteProvider(connection: fixture.connection(.ftp), password: "memory-only-secret")
        ]
        let unknown = fixture.root.appendingPathComponent("unknown-length-bounded")
        webExpectThrows(try providers[0].searchDownload(path: "/unknown-length-search", to: unknown, maximumBytes: 3,
            cancellation: TransferCancellation(), progress: { _ in }))
        #expect(((try? Data(contentsOf: unknown).count) ?? 0) <= 3)
        for (index, provider) in providers.enumerated() {
            let output = fixture.root.appendingPathComponent("bounded-\(index)")
            webExpectThrows(try provider.searchDownload(path: "/hello space.txt", to: output, maximumBytes: 3,
                cancellation: TransferCancellation(), progress: { _ in }))
            let size = (try? Data(contentsOf: output).count) ?? 0
            #expect(size <= 3)
            try provider.searchDownload(path: "/hello space.txt", to: output, maximumBytes: 18,
                cancellation: TransferCancellation(), progress: { _ in })
            #expect(try Data(contentsOf: output) == Data("hello remote world".utf8))
            var options = SearchOptions(roots: []); options.contentMode = .literal; options.contentQuery = "remote"
            var found: [ProviderSearchResult] = []
            let summary = ProviderSearchEngine.runRemote(provider: provider, root: "/hello space.txt", request: SearchRequest(options: options), cancellation: ProviderSearchCancellation()) {
                if case .result(let result) = $0 { found.append(result) }
            }
            #expect(summary.errors == 0); #expect(found.count == 1)
        }
    }

    @Test func directoryUploadMoveVerifiesDAVBytesBeforeLocalDeletionAndDownloadMoveRefusesCollections() throws {
        let fixture = try WebRemoteFixture(); defer { fixture.stop() }
        let provider = WebRemoteProvider(connection: fixture.connection(.webdav), password: "memory-only-secret")
        let source = fixture.root.appendingPathComponent("move-tree")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("empty"), withIntermediateDirectories: false)
        try Data("first file".utf8).write(to: source.appendingPathComponent("a"))
        try Data("nested bytes".utf8).write(to: source.appendingPathComponent("sub/b"))
        let upload = try RemoteDirectoryTransfer.prepareUpload(provider: provider, sources: [source], into: "/", policy: .requireNew)
        let report = try RemoteDirectoryTransfer.move(provider: provider, plan: upload)
        #expect(report.moving && report.retainedSources.isEmpty && report.failedSourceRemovals.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try provider.stat(path: "/move-tree/empty", cancellation: TransferCancellation())?.isDirectory == true)
        let check = fixture.root.appendingPathComponent("move-readback")
        try provider.download(path: "/move-tree/sub/b", to: check, resumeOffset: 0, cancellation: TransferCancellation(), progress: { _ in })
        #expect(try Data(contentsOf: check) == Data("nested bytes".utf8))
        let destination = fixture.root.appendingPathComponent("refused-move")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let remoteEntry = try provider.stat(path: "/move-tree", cancellation: TransferCancellation())
        let entry = try #require(remoteEntry)
        let download = try RemoteDirectoryTransfer.prepareDownload(provider: provider, entries: [entry], into: destination, policy: .requireNew)
        webExpectThrows(try RemoteDirectoryTransfer.move(provider: provider, plan: download))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        #expect(try provider.stat(path: "/move-tree/a", cancellation: TransferCancellation())?.size == 10)
        #expect(try provider.stat(path: "/move-tree/sub/b", cancellation: TransferCancellation())?.size == 12)
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
        // Respect the CI-selected Python rather than Apple's developer-tools shim.
        // FAR_TEST_PYTHON also allows a specific interpreter in local runs.
        let python = ProcessInfo.processInfo.environment["FAR_TEST_PYTHON"] ?? "python3"
        process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [python, "-u", script.path, root.path] + (tls ? ["tls"] : [])
        let diagnostics = root.appendingPathComponent("stderr.log")
        _ = FileManager.default.createFile(atPath: diagnostics.path, contents: nil)
        let stderr = try FileHandle(forWritingTo: diagnostics)
        defer { try? stderr.close() }
        process.standardOutput = FileHandle.nullDevice; process.standardError = stderr
        do { try process.run() } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        let ready = root.appendingPathComponent("ports.json")
        // Bound the handshake while allowing interpreter startup under CI load.
        let startupTimeout: TimeInterval = 10
        let deadline = ProcessInfo.processInfo.systemUptime + startupTimeout
        let requiredPorts = tls ? ["http", "ftp", "https", "ftps"] : ["http", "ftp"]
        var values: [String: Int]?
        while ProcessInfo.processInfo.systemUptime < deadline && process.isRunning {
            if let data = try? Data(contentsOf: ready),
               let result = try? JSONDecoder().decode([String: Int].self, from: data),
               requiredPorts.allSatisfy({ (1...65535).contains(result[$0] ?? 0) }) {
                values = result; break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard let values else {
            let timedOut = process.isRunning
            if timedOut { process.terminate() }
            process.waitUntilExit()
            let detail = (try? String(contentsOf: diagnostics, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: root)
            let reason = timedOut ? "readiness handshake timed out after \(Int(startupTimeout)) seconds" : "exited with status \(process.terminationStatus)"
            throw NSError(domain: "WebRemoteFixture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Local fixture (\(python)) \(reason). stderr: \(detail.isEmpty ? "<empty>" : detail)"
            ])
        }
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

extension WebRemoteProviderTests {
    @Test func testLoopbackDAVDirectoryFileAboveSearchCeilingTransfersBothWays() throws {
        let fixture = try WebRemoteFixture(); defer { fixture.stop() }
        var connection = fixture.connection(.webdav); connection.timeoutSeconds = 20
        let provider = WebRemoteProvider(connection: connection, password: "memory-only-secret")
        let source = fixture.root.appendingPathComponent("large-tree")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let bytes = Data(repeating: 0x5a, count: 65 * 1024 * 1024)
        try bytes.write(to: source.appendingPathComponent("large.bin"))
        let upload = try RemoteDirectoryTransfer.prepareUpload(provider: provider, sources: [source], into: "/", policy: .requireNew)
        #expect(upload.transferBytes == Int64(bytes.count))
        _ = try RemoteDirectoryTransfer.copy(provider: provider, plan: upload)
        let destination = fixture.root.appendingPathComponent("large-download")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let entry = try #require(try provider.stat(path: "/large-tree", cancellation: TransferCancellation()))
        let download = try RemoteDirectoryTransfer.prepareDownload(provider: provider, entries: [entry], into: destination, policy: .requireNew)
        _ = try RemoteDirectoryTransfer.copy(provider: provider, plan: download)
        #expect(try Data(contentsOf: destination.appendingPathComponent("large-tree/large.bin")) == bytes)
        #expect(try Data(contentsOf: source.appendingPathComponent("large.bin")) == bytes)
    }

    @Test func testLoopbackDAVDirectoryTransferNewTreeAndExplicitMergeSkip() throws {
        let fixture = try WebRemoteFixture(); defer { fixture.stop() }
        let p = WebRemoteProvider(connection: fixture.connection(.webdav), password: "memory-only-secret")
        let token = TransferCancellation()
        let local = fixture.root.appendingPathComponent("directory-transfer-source")
        let tree = local.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("empty"), withIntermediateDirectories: false)
        try Data("original".utf8).write(to: tree.appendingPathComponent("a"))
        try Data("nested".utf8).write(to: tree.appendingPathComponent("sub/b"))
        let fresh = try RemoteDirectoryTransfer.prepareUpload(provider: p, sources: [tree], into: "/", policy: .requireNew)
        #expect(fresh.copies.count == 1 && fresh.directoryCount == 3 && fresh.fileCount == 2)
        #expect(try p.stat(path: "/tree", cancellation: token) == nil)
        _ = try RemoteDirectoryTransfer.copy(provider: p, plan: fresh)
        #expect(try p.stat(path: "/tree/sub/b", cancellation: token)?.size == 6)
        #expect(try p.stat(path: "/tree/empty", cancellation: token)?.isDirectory == true)
        try Data("changed local".utf8).write(to: tree.appendingPathComponent("a"))
        try Data("new child".utf8).write(to: tree.appendingPathComponent("sub/c"))
        let merge = try RemoteDirectoryTransfer.prepareUpload(provider: p, sources: [tree], into: "/", policy: .mergeSkippingExisting)
        #expect(merge.copies.map(\.destination) == ["/tree/sub/c"] && merge.skipped.count == 2 && merge.transferBytes == 9)
        let uploaded = try RemoteDirectoryTransfer.copy(provider: p, plan: merge)
        #expect(uploaded.completed.count == 1 && uploaded.skipped.count == 2)
        let check = local.appendingPathComponent("server-a")
        try p.download(path: "/tree/a", to: check, resumeOffset: 0, cancellation: token, progress: { _ in })
        #expect(try Data(contentsOf: check) == Data("original".utf8))
        let destination = fixture.root.appendingPathComponent("directory-transfer-download")
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("tree/sub"), withIntermediateDirectories: true)
        try Data("local kept".utf8).write(to: destination.appendingPathComponent("tree/a"))
        try Data("local only".utf8).write(to: destination.appendingPathComponent("tree/sub/local-only"))
        let root = try #require(try p.stat(path: "/tree", cancellation: token))
        let downPlan = try RemoteDirectoryTransfer.prepareDownload(provider: p, entries: [root], into: destination, policy: .mergeSkippingExisting)
        #expect(downPlan.skipped.map(\.source) == ["/tree/a"] && downPlan.copies.count == 3)
        _ = try RemoteDirectoryTransfer.copy(provider: p, plan: downPlan)
        #expect(try Data(contentsOf: destination.appendingPathComponent("tree/a")) == Data("local kept".utf8))
        #expect(try Data(contentsOf: destination.appendingPathComponent("tree/sub/b")) == Data("nested".utf8))
        #expect(try Data(contentsOf: destination.appendingPathComponent("tree/sub/c")) == Data("new child".utf8))
        #expect(try Data(contentsOf: destination.appendingPathComponent("tree/sub/local-only")) == Data("local only".utf8))
        #expect(try Data(contentsOf: tree.appendingPathComponent("a")) == Data("changed local".utf8))
        // The general bounded transfer method accepts ceilings above the search
        // limit while still refusing bytes beyond the reviewed file length.
        try p.boundedDownload(path: "/tree/a", to: check, maximumBytes: 65 * 1024 * 1024, cancellation: token, progress: { _ in })
        #expect(try Data(contentsOf: check) == Data("original".utf8))
        #expect(throws: (any Error).self) { try p.boundedDownload(path: "/tree/a", to: check, maximumBytes: 1, cancellation: token, progress: { _ in }) }
    }

    @Test func testLoopbackFTPPreviewRecursiveDeleteAndRefusedUnsafeRename() throws {
        let fixture = try WebRemoteFixture(); defer { fixture.stop() }
        let p = FTPRemoteProvider(connection: fixture.connection(.ftp), password: "memory-only-secret")
        let token = TransferCancellation()
        try p.makeDirectory(path: "/tree", cancellation: token)
        try p.makeDirectory(path: "/tree/sub", cancellation: token)
        let local = fixture.root.appendingPathComponent("tree-source")
        try Data("retained bytes".utf8).write(to: local)
        try p.upload(from: local, to: "/tree/sub/file", cancellation: token, progress: { _ in })
        let root = try #require(try p.stat(path: "/tree", cancellation: token))
        #expect(throws: (any Error).self) { try RemoteTreeOperations.prepareMove(provider: p, entries: [root], to: "/renamed", intoDirectory: false) }
        #expect(try p.stat(path: "/tree/sub/file", cancellation: token) != nil)
        let preview = try RemoteTreeOperations.prepareDelete(provider: p, entries: [root])
        #expect(preview.directoryCount == 2 && preview.fileCount == 1)
        // Fresh child after preview must stop the whole job before the first deletion.
        try p.upload(from: local, to: "/tree/new", cancellation: token, progress: { _ in })
        #expect(throws: RemoteTreeOperationError.self) { try RemoteTreeOperations.delete(provider: p, plan: preview) }
        #expect(try p.stat(path: "/tree/sub/file", cancellation: token) != nil)
        // RMD itself refuses a nonempty folder, closing the final-list/new-child race.
        #expect(throws: (any Error).self) { try p.remove(path: "/tree", isDirectory: true, cancellation: token) }
        #expect(try p.stat(path: "/tree/new", cancellation: token) != nil)
        let fresh = try RemoteTreeOperations.prepareDelete(provider: p, entries: [try #require(try p.stat(path: "/tree", cancellation: token))])
        let report = try RemoteTreeOperations.delete(provider: p, plan: fresh)
        #expect(report.completed.count == 4)
        #expect(try p.stat(path: "/tree", cancellation: token) == nil)
    }

    @Test func testLoopbackDAVMoveUsesNoOverwriteAndRefusesRecursiveDelete() throws {
        let fixture = try WebRemoteFixture(); defer { fixture.stop() }
        let p = WebRemoteProvider(connection: fixture.connection(.webdav), password: "memory-only-secret")
        let token = TransferCancellation()
        let source = try #require(try p.stat(path: "/hello space.txt", cancellation: token))
        let plan = try RemoteTreeOperations.prepareMove(provider: p, entries: [source], to: "/new name.txt", intoDirectory: false)
        _ = try RemoteTreeOperations.move(provider: p, plan: plan)
        #expect(try p.stat(path: "/new name.txt", cancellation: token)?.size == source.size)
        try p.makeDirectory(path: "/dav-folder", cancellation: token)
        let folder = try #require(try p.stat(path: "/dav-folder", cancellation: token))
        #expect(throws: (any Error).self) { try RemoteTreeOperations.prepareDelete(provider: p, entries: [folder]) }
        #expect(try p.stat(path: "/dav-folder", cancellation: token) != nil)
        try p.makeDirectory(path: "/dav-folder/sub", cancellation: token)
        let local = fixture.root.appendingPathComponent("dav-tree-upload")
        try Data("tree bytes".utf8).write(to: local)
        try p.upload(from: local, to: "/dav-folder/sub/file", cancellation: token, progress: { _ in })
        let directoryMove = try RemoteTreeOperations.prepareMove(provider: p, entries: [try #require(try p.stat(path: "/dav-folder", cancellation: token))], to: "/dav-renamed", intoDirectory: false)
        _ = try RemoteTreeOperations.move(provider: p, plan: directoryMove)
        #expect(try p.stat(path: "/dav-folder", cancellation: token) == nil)
        #expect(try p.stat(path: "/dav-renamed/sub/file", cancellation: token)?.size == 10)
        // Server-side Overwrite:F rejects even a direct conflicting request.
        #expect(throws: (any Error).self) { try p.rename(from: "/dav-renamed", to: "/new name.txt", replace: false, cancellation: token) }
        #expect(try p.stat(path: "/dav-renamed/sub/file", cancellation: token) != nil)
        #expect(try p.stat(path: "/new name.txt", cancellation: token)?.size == source.size)
    }
}


extension SFTPPasswordTests {
    @Test func copiesSFTPTreeIntoWebDAVAndMovesBothDirections() throws {
        let sshFixture = try PasswordSSHFixture(); defer { sshFixture.stop() }; try sshFixture.trust()
        let webFixture = try WebRemoteFixture(); defer { webFixture.stop() }
        let ssh = sshFixture.provider
        defer { ssh.closeConnection() }
        let web = WebRemoteProvider(connection: webFixture.connection(.webdav), password: "memory-only-secret")
        let token = TransferCancellation()
        let file = webFixture.root.appendingPathComponent("cross-payload")
        let bytes = Data("binary content \0 α 🐈".utf8)
        try bytes.write(to: file)
        try ssh.makeDirectory(path: "/bundle", cancellation: token)
        try ssh.makeDirectory(path: "/bundle/empty", cancellation: token)
        try ssh.upload(from: file, to: "/bundle/Привет", cancellation: token, progress: { _ in })
        let tree = try #require(try ssh.stat(path: "/bundle", cancellation: token))
        let copy = try RemoteDirectoryTransfer.prepareRemote(source: ssh, destination: web, entries: [tree], into: "/",
            policy: .requireNew, move: false)
        let report = try RemoteDirectoryTransfer.copy(provider: web, plan: copy, sourceProvider: ssh)
        #expect(report.completed.map(\.destination) == ["/bundle"])
        #expect(try ssh.stat(path: "/bundle/Привет", cancellation: token) != nil)
        #expect(try web.stat(path: "/bundle/empty", cancellation: token)?.isDirectory == true)
        try web.download(path: "/bundle/Привет", to: file, resumeOffset: 0, cancellation: token, progress: { _ in })
        #expect(try Data(contentsOf: file) == bytes)

        try web.makeDirectory(path: "/moved", cancellation: token)
        let move = try RemoteDirectoryTransfer.prepareRemote(source: ssh, destination: web, entries: [tree], into: "/moved",
            policy: .requireNew, move: true)
        let moved = try RemoteDirectoryTransfer.copy(provider: web, plan: move, move: true, sourceProvider: ssh)
        #expect(Set(moved.removedSources) == ["/bundle", "/bundle/empty", "/bundle/Привет"])
        #expect(try ssh.stat(path: "/bundle", cancellation: token) == nil)
        let davTree = try #require(try web.stat(path: "/moved/bundle", cancellation: token))
        webExpectThrows(try RemoteDirectoryTransfer.prepareRemote(source: web, destination: ssh, entries: [davTree],
            into: "/", policy: .requireNew, move: true))

        let davFile = try #require(try web.stat(path: "/moved/bundle/Привет", cancellation: token))
        let returnMove = try RemoteDirectoryTransfer.prepareRemote(source: web, destination: ssh, entries: [davFile],
            into: "/", policy: .requireNew, move: true)
        let returned = try RemoteDirectoryTransfer.copy(provider: ssh, plan: returnMove, move: true, sourceProvider: web)
        #expect(returned.removedSources == ["/moved/bundle/Привет"])
        #expect(try web.stat(path: "/moved/bundle/Привет", cancellation: token) == nil)
        try ssh.download(path: "/Привет", to: file, resumeOffset: 0, cancellation: token, progress: { _ in })
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func crossConnectionRejectsStaleEndpointsAndCancelsBeforeSourceDeletion() throws {
        let sshFixture = try PasswordSSHFixture(); defer { sshFixture.stop() }; try sshFixture.trust()
        let webFixture = try WebRemoteFixture(); defer { webFixture.stop() }
        let ssh = sshFixture.provider
        defer { ssh.closeConnection() }
        let web = WebRemoteProvider(connection: webFixture.connection(.webdav), password: "memory-only-secret")
        let token = TransferCancellation()
        let file = webFixture.root.appendingPathComponent("race-data")
        let source = "/candidate.txt"
        func preview(_ entry: RemoteEntry) throws -> RemoteDirectoryTransferPlan {
            try RemoteDirectoryTransfer.prepareRemote(source: ssh, destination: web, entries: [entry], into: "/",
                policy: .requireNew, move: true)
        }
        try Data("old".utf8).write(to: file)
        try ssh.upload(from: file, to: source, cancellation: token, progress: { _ in })
        let original = try #require(try ssh.stat(path: source, cancellation: token))
        let stale = try preview(original)
        // Model an independent writer in the fixture's backing directory. Its
        // SFTP server intentionally does not advertise POSIX overwrite rename.
        try Data("changed source".utf8).write(to: sshFixture.root.appendingPathComponent(original.name))
        #expect(try ssh.stat(path: source, cancellation: token)?.size != original.size)
        webExpectThrows(try RemoteDirectoryTransfer.copy(provider: web, plan: stale, move: true, sourceProvider: ssh)) {
            #expect(($0 as? RemoteDirectoryTransferFailure)?.outcomeUnknown == false)
        }
        #expect(try web.stat(path: source, cancellation: token) == nil)
        let entry = try #require(try ssh.stat(path: source, cancellation: token))
        let plan = try preview(entry)
        let swappedProvider = sshFixture.provider
        webExpectThrows(try RemoteDirectoryTransfer.copy(provider: web, plan: plan, move: true, sourceProvider: swappedProvider))
        try Data("new target".utf8).write(to: file)
        try web.upload(from: file, to: source, cancellation: token, progress: { _ in })
        webExpectThrows(try RemoteDirectoryTransfer.copy(provider: web, plan: plan, move: true, sourceProvider: ssh))
        try web.download(path: source, to: file, resumeOffset: 0, cancellation: token, progress: { _ in })
        #expect(try Data(contentsOf: file) == Data("new target".utf8))
        #expect(try ssh.stat(path: source, cancellation: token) == entry)

        try web.remove(path: source, isDirectory: false, cancellation: token)
        let cancel = TransferCancellation()
        let cancellationPlan = try preview(entry)
        webExpectThrows(try RemoteDirectoryTransfer.copy(provider: web, plan: cancellationPlan, move: true, sourceProvider: ssh,
            cancellation: cancel, progress: { update in
                if update.path.hasPrefix("Скопировано поддеревьев") { cancel.cancel() }
            })) { error in
                let partial = error as? RemoteDirectoryTransferFailure
                #expect(partial?.report.completed.map(\.destination) == [source])
                #expect(partial?.report.removedSources.isEmpty == true)
                #expect(partial?.outcomeUnknown == false)
            }
        #expect(try ssh.stat(path: source, cancellation: token) == entry)
        try web.download(path: source, to: file, resumeOffset: 0, cancellation: token, progress: { _ in })
        #expect(try Data(contentsOf: file) == Data("changed source".utf8))
    }

    @Test func crossConnectionPreservesSourceWhenDestinationAcknowledgmentIsLost() throws {
        let sshFixture = try PasswordSSHFixture(); defer { sshFixture.stop() }; try sshFixture.trust()
        let webFixture = try WebRemoteFixture(); defer { webFixture.stop() }
        let ssh = sshFixture.provider
        defer { ssh.closeConnection() }
        let web = WebRemoteProvider(connection: webFixture.connection(.webdav), password: "memory-only-secret")
        let token = TransferCancellation()
        let path = "/lost-move-ack.txt"
        let payload = webFixture.root.appendingPathComponent("upload")
        try Data("published bytes".utf8).write(to: payload)
        try ssh.upload(from: payload, to: path, cancellation: token, progress: { _ in })
        let entry = try #require(try ssh.stat(path: path, cancellation: token))
        let plan = try RemoteDirectoryTransfer.prepareRemote(source: ssh, destination: web, entries: [entry],
            into: "/", policy: .requireNew, move: true)
        webExpectThrows(try RemoteDirectoryTransfer.copy(provider: web, plan: plan, move: true, sourceProvider: ssh)) {
            let error = $0 as? RemoteDirectoryTransferFailure
            #expect(error?.outcomeUnknown == true)
            #expect(error?.report.completed.isEmpty == true)
            #expect(error?.report.removedSources.isEmpty == true)
        }
        #expect(try ssh.stat(path: path, cancellation: token) == entry)
        #expect(try web.stat(path: path, cancellation: token)?.size == entry.size)
        let requests = webFixture.root.appendingPathComponent("lost-move-requests")
        #expect(try String(contentsOf: requests, encoding: .utf8) == "MOVE\n")
    }
}

extension WebRemoteProviderTests {
    @Test func conditionalWebDAVDeletePendingIsReportedAsUnknownWithoutRetry() throws {
        let webFixture = try WebRemoteFixture(); defer { webFixture.stop() }
        let web = WebRemoteProvider(connection: webFixture.connection(.webdav), password: "memory-only-secret")
        let token = TransferCancellation()
        let payload = webFixture.root.appendingPathComponent("payload")
        let path = "/pending-delete.txt", bytes = Data("pending server deletion".utf8)
        try bytes.write(to: payload)
        try web.upload(from: payload, to: path, cancellation: token, progress: { _ in })
        let entry = try #require(try web.stat(path: path, cancellation: token))
        let local = webFixture.root.resolvingSymlinksInPath().appendingPathComponent("copies")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
        let plan = try RemoteDirectoryTransfer.prepareDownload(provider: web, entries: [entry], into: local, policy: .requireNew, move: true)
        let report = try RemoteDirectoryTransfer.move(provider: web, plan: plan)
        #expect(report.completed.count == 1 && report.removedSources.isEmpty)
        #expect(report.failedSourceRemovals.contains { $0.source == path && $0.outcomeUnknown && $0.reason.contains("202") })
        #expect(try web.stat(path: path, cancellation: token) == entry)
        #expect(try Data(contentsOf: local.appendingPathComponent(entry.name)) == bytes)
        let log = webFixture.root.appendingPathComponent("pending-delete-requests")
        let version = try #require(entry.version)
        #expect(try String(contentsOf: log, encoding: .utf8) == version + "\n")

        let single = local.appendingPathComponent("single")
        webExpectThrows(try RemoteTransferEngine.download(provider: web, path: path, to: single, move: true)) {
            #expect($0.localizedDescription.contains("202"))
        }
        #expect(try Data(contentsOf: single) == bytes)
        #expect(try String(contentsOf: log, encoding: .utf8) == version + "\n" + version + "\n")
    }

    @Test func crossConnectionAliasPermitsOnlyNewNamesAndPreservesTheSource() throws {
        let fixture = try WebRemoteFixture(); defer { fixture.stop() }
        let source = WebRemoteProvider(connection: fixture.connection(.webdav), password: "memory-only-secret")
        var alternate = fixture.connection(.webdav); alternate.host = "localhost"
        let target = WebRemoteProvider(connection: alternate, password: "memory-only-secret")
        let token = TransferCancellation(), path = "/hello space.txt"
        let entry = try #require(try source.stat(path: path, cancellation: token))
        let preview = try RemoteDirectoryTransfer.prepareRemote(source: source, destination: target, entries: [entry], into: "/",
            policy: .mergeSkippingExisting, move: false)
        #expect(preview.conflicts.first?.canReplace == false)
        webExpectThrows(try RemoteDirectoryTransfer.resolve(provider: target, plan: preview, decisions: [path: .append], sourceProvider: source))
        let renamed = try RemoteDirectoryTransfer.resolve(provider: target, plan: preview,
            decisions: [path: .rename("alias-copy.txt")], sourceProvider: source)
        let report = try RemoteDirectoryTransfer.copy(provider: target, plan: renamed, sourceProvider: source)
        #expect(report.completed.map(\.destination) == ["/alias-copy.txt"])
        #expect(try source.stat(path: path, cancellation: token) == entry)
        #expect(try target.stat(path: "/alias-copy.txt", cancellation: token)?.size == entry.size)
    }

    @Test func localToWebDAVResolvesAppendResumeNewerAndVerifiesPrefixBeforeAnyWrite() throws {
        let webFixture = try WebRemoteFixture(); defer { webFixture.stop() }
        let web = WebRemoteProvider(connection: webFixture.connection(.webdav), password: "memory-only-secret")
        let token = TransferCancellation()
        let file = webFixture.root.appendingPathComponent("conflict-data")
        let folder = webFixture.root.resolvingSymlinksInPath().appendingPathComponent("local-sources")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let paths = ["/append", "/resume", "/newer", "/wrong-prefix"]
        let files = paths.map { folder.appendingPathComponent(String($0.dropFirst())) }
        for (path, data) in zip(paths, ["existing ", "source ", "older data", "bad"]) {
            try Data(data.utf8).write(to: file)
            try web.upload(from: file, to: path, cancellation: token, progress: { _ in })
        }
        for source in files { try Data("source contents".utf8).write(to: source) }
        let preview = try RemoteDirectoryTransfer.prepareUpload(provider: web, sources: files, into: "/", policy: .mergeSkippingExisting)
        // The conflict editor keys its decisions by the reviewed source path,
        // which normalizes system aliases such as /var to /private/var.
        let sources = Dictionary(uniqueKeysWithValues: preview.conflicts.map { ($0.mapping.destination, $0.mapping.source) })
        let append = try #require(sources["/append"])
        let resume = try #require(sources["/resume"])
        let newer = try #require(sources["/newer"])
        let wrongPrefix = try #require(sources["/wrong-prefix"])
        let rejected = try RemoteDirectoryTransfer.resolve(provider: web, plan: preview,
            decisions: [append: .append, wrongPrefix: .resume])
        webExpectThrows(try RemoteDirectoryTransfer.copy(provider: web, plan: rejected)) {
            guard let failure = $0 as? RemoteDirectoryTransferFailure,
                  case .verification? = failure.cause as? RemoteTransferError else {
                Issue.record("Expected a prefix verification failure: \($0)")
                return
            }
            #expect(failure.report.completed.isEmpty)
        }
        try web.download(path: "/append", to: file, resumeOffset: 0, cancellation: token, progress: { _ in })
        #expect(try Data(contentsOf: file) == Data("existing ".utf8))
        let reviewed = try RemoteDirectoryTransfer.resolve(provider: web, plan: preview,
            decisions: [append: .append, resume: .resume, newer: .newer])
        let result = try RemoteDirectoryTransfer.copy(provider: web, plan: reviewed)
        #expect(result.completed.count == 3)
        #expect(result.skipped.map(\.source) == [wrongPrefix])
        for (path, expected) in zip(paths, ["existing source contents", "source contents", "source contents", "bad"]) {
            try web.download(path: path, to: file, resumeOffset: 0, cancellation: token, progress: { _ in })
            #expect(try Data(contentsOf: file) == Data(expected.utf8))
        }
    }
}
