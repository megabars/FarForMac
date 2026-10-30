import Foundation
import Testing
@testable import FarCore

struct NetworkModelsTests {
    @Test func validatesConnectionAndOpaquePaths() throws {
        try NetworkConnection(kind: .sftp, host: "::1", username: "test", rootPath: "/Папка с пробелом").validate()
        for host in ["-oProxyCommand=bad", "host user", "user@host", "host/path", "bad\nname"] {
            #expect(throws: (any Error).self) { try NetworkConnection(kind: .sftp, host: host).validate() }
        }
        for path in ["relative", "/../escape", "/a/./b", "/a//b", "/a\nname", "/a\\b"] { #expect(throws: (any Error).self) { try RemotePath.validate(path) } }
        #expect(try RemotePath.child("a ; $(literal).txt", of: "/") == "/a ; $(literal).txt")
        #expect(throws: (any Error).self) { try RemotePath.child("../escape", of: "/") }
    }
    @Test func profilesPersistOnlyMetadataPrivately() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Connections.json")
        let profile = NetworkConnection(name: "Fixture", kind: .webdavs, host: "example.org", username: "tester")
        try NetworkProfileStore.save([profile], to: url)
        #expect(try NetworkProfileStore.load(from: url) == [profile])
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        #expect(json[0]["password"] == nil)
        #expect(json[0]["secret"] == nil)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(throws: (any Error).self) { try NetworkProfileStore.save([profile, profile], to: url) }
        try Data("not json".utf8).write(to: url)
        #expect(throws: (any Error).self) { try NetworkProfileStore.load(from: url) }
    }
}
