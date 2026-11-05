import Foundation
import Testing
@testable import FarCore

struct SavedNetworkProfilesTests {
    @Test func olderProfilesRemainInTheRootAndKeepIdentity() throws {
        let original = NetworkConnection(name: "Old / literal name", kind: .sftp, host: "example.test")
        let data = try JSONEncoder().encode(original)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "profileGroup")
        let decoded = try JSONDecoder().decode(NetworkConnection.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == original)
        #expect(decoded.profileGroup.isEmpty)
    }

    @Test func nestedPathsKeepIdentityAndRejectCaseInsensitiveCollisions() throws {
        let profile = NetworkConnection(kind: .sftp, host: "example.test")
        let grouped = try SavedNetworkProfiles.assigningPath("Work\\Europe/Storage", to: profile)
        #expect(grouped.id == profile.id)
        #expect(grouped.profileGroup == ["Work", "Europe"])
        #expect(grouped.name == "Storage")
        #expect(SavedNetworkProfiles.matches(grouped.profileGroup, prefix: ["work"]))
        #expect(!SavedNetworkProfiles.matches(grouped.profileGroup, prefix: ["Workshop"]))
        var profiles = [grouped]
        let duplicate = try SavedNetworkProfiles.assigningPath("work/europe/storage", to: NetworkConnection(kind: .ftp, host: "other.test"))
        #expect(throws: NetworkError.self) { try SavedNetworkProfiles.upsert(duplicate, in: &profiles) }
        let moved = try SavedNetworkProfiles.assigningPath("Archive/Storage", to: grouped)
        try SavedNetworkProfiles.upsert(moved, in: &profiles)
        #expect(profiles == [moved])
        for invalid in ["", "/name", "../name", "group//name", "group/", "a/.", "a/b\u{0000}"] {
            #expect(throws: NetworkError.self) { try SavedNetworkProfiles.assigningPath(invalid, to: grouped) }
        }
    }

    @Test func netBoxExportRoundTripsProtocolsAndUnicodeWithoutSecrets() throws {
        for kind in NetworkProtocol.allCases {
            let profile = NetworkConnection(name: "Сервер 100% & XML", kind: kind, host: "example.test",
                username: "тестер", rootPath: "/a & b", sftpAuthenticationMode: kind == .sftp ? .password : .keyAgent, profileGroup: ["Работа", "Europe"])
            let xml = try NetBoxSessionFile.encode(profile)
            let exported = String(decoding: xml, as: UTF8.self)
            #expect(exported.contains("<NetBox version=\"2.1\">"))
            #expect(!exported.contains(profile.id.uuidString))
            #expect(!exported.contains("<Password>"))
            let result = try #require(try NetBoxSessionFile.decode(xml).first)
            #expect(result.id != profile.id)
            var expected = profile
            expected.id = result.id
            #expect(result == expected)
            #expect(!NetBoxSessionFile.fileName(for: profile).contains("/"))
        }
    }

    @Test func netBoxImportReadsSettingsAndIgnoresSecrets() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <NetBox version="2.1"><Sessions><Session name="Group/Example%20server">
            <HostName>example.test</HostName><PortNumber>443</PortNumber><UserName>demo</UserName>
            <FSProtocol>WebDAV</FSProtocol><Ftps>2</Ftps><RemoteDirectory>/files</RemoteDirectory>
            <Password>encrypted-secret</Password><PasswordPlain>clear-secret</PasswordPlain>
        </Session></Sessions></NetBox>
        """
        let imported = try #require(try NetBoxSessionFile.decode(Data(xml.utf8)).first)
        #expect(imported.kind == .webdavs)
        #expect(imported.port == 443)
        #expect(imported.rootPath == "/files")
        #expect(SavedNetworkProfiles.path(for: imported) == "Group/Example server")
        let output = String(decoding: try NetBoxSessionFile.encode(imported), as: UTF8.self)
        #expect(!output.contains("secret"))
        #expect(!output.contains("<Password"))
    }

    @Test func netBoxExchangeRejectsEntityDefinitionsAndRoutesItCannotRepresent() throws {
        let template = "<NetBox><Sessions><Session name=\"Remote\"><HostName>example.test</HostName>%@</Session></Sessions></NetBox>"
        for settings in ["<Tunnel>1</Tunnel>", "<ProxyMethod>SOCKS5</ProxyMethod>", "<FSProtocol>S3</FSProtocol>", "<PortNumber>oops</PortNumber>"] {
            #expect(throws: NetworkError.self) {
                try NetBoxSessionFile.decode(Data(String(format: template, settings).utf8))
            }
        }
        let externalEntity = "<!DOCTYPE NetBox [<!ENTITY test SYSTEM \"file:///private/etc/hosts\">]>" +
            String(format: template, "<UserName>&test;</UserName>")
        #expect(throws: NetworkError.self) { try NetBoxSessionFile.decode(Data(externalEntity.utf8)) }
        let route = [SFTPJumpHost(host: "gateway.test", username: "tester")]
        let profile = NetworkConnection(kind: .sftp, host: "example.test", sftpJumpHosts: route)
        #expect(throws: NetworkError.self) { try NetBoxSessionFile.encode(profile) }
    }
}
