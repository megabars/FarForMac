import Foundation
import Testing
@testable import FarCore

struct NetworkModelsTests {
    @Test func sftpAuthenticationMetadataRoundTripsAndLegacyDefaultsToKeys() throws {
        let profile = NetworkConnection(kind: .sftp, host: "example.org", username: "tester", sftpAuthenticationMode: .password)
        let encoded = try JSONEncoder().encode(profile)
        #expect(try JSONDecoder().decode(NetworkConnection.self, from: encoded) == profile)
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["sftpAuthenticationMode"] as? String == "password")
        #expect(json["password"] == nil)
        json.removeValue(forKey: "sftpAuthenticationMode")
        let legacy = try JSONDecoder().decode(NetworkConnection.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.sftpAuthenticationMode == .keyAgent)
        json["sftpAuthenticationMode"] = "unrecognized"
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(NetworkConnection.self, from: JSONSerialization.data(withJSONObject: json))
        }
    }
    @Test func validatesConnectionAndOpaquePaths() throws {
        try NetworkConnection(kind: .sftp, host: "::1", username: "test", rootPath: "/Папка с пробелом").validate()
        for host in ["-oProxyCommand=bad", "host user", "user@host", "host/path", "bad\nname"] {
            #expect(throws: (any Error).self) { try NetworkConnection(kind: .sftp, host: host).validate() }
        }
        for path in ["relative", "/../escape", "/a/./b", "/a//b", "/a\nname", "/a\\b"] { #expect(throws: (any Error).self) { try RemotePath.validate(path) } }
        #expect(try RemotePath.child("a ; $(literal).txt", of: "/") == "/a ; $(literal).txt")
        #expect(throws: (any Error).self) { try RemotePath.child("../escape", of: "/") }
    }
    @Test func jumpHostsRoundTripAndOlderProfilesDefaultToNoGateways() throws {
        let jump = SFTPJumpHost(host: "gateway.example.org", port: 2222, username: "jump", privateKeyPath: "/keys/jump")
        let profile = NetworkConnection(kind: .sftp, host: "target.example.org", username: "target", sftpJumpHosts: [jump])
        try profile.validate()
        let encoded = try JSONEncoder().encode(profile)
        #expect(try JSONDecoder().decode(NetworkConnection.self, from: encoded) == profile)
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "sftpJumpHosts")
        let legacy = try JSONDecoder().decode(NetworkConnection.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.sftpJumpHosts.isEmpty)
        #expect(legacy.sftpAuthenticationMode == .keyAgent)
    }
    @Test func jumpHostsRejectInvalidMetadataAndEndpointCycles() throws {
        let valid = SFTPJumpHost(host: "gateway.example.org", username: "jump")
        for invalid in [
            SFTPJumpHost(host: "-oProxyCommand=bad", username: "jump"),
            SFTPJumpHost(host: "gateway.example.org", port: 0, username: "jump"),
            SFTPJumpHost(host: "gateway.example.org", username: ""),
            SFTPJumpHost(host: "gateway.example.org", username: "bad user"),
            SFTPJumpHost(host: "gateway.example.org", username: "bad\tuser"),
            SFTPJumpHost(host: "gateway.example.org", username: "jump", privateKeyPath: "relative"),
            SFTPJumpHost(host: "TARGET.EXAMPLE.ORG", username: "other")
        ] {
            #expect(throws: (any Error).self) {
                try NetworkConnection(kind: .sftp, host: "target.example.org", sftpJumpHosts: [invalid]).validate()
            }
        }
        #expect(throws: (any Error).self) {
            try NetworkConnection(kind: .sftp, host: "target.example.org", sftpJumpHosts: [valid, valid]).validate()
        }
        #expect(throws: (any Error).self) {
            let jumps = (0..<5).map { SFTPJumpHost(host: "gateway\($0).example.org", username: "jump") }
            try NetworkConnection(kind: .sftp, host: "target.example.org", sftpJumpHosts: jumps).validate()
        }
        #expect(throws: (any Error).self) {
            try NetworkConnection(kind: .ftp, host: "target.example.org", sftpJumpHosts: [valid]).validate()
        }
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
