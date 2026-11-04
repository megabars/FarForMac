import Foundation
import Testing
@testable import FarCore

struct SSHConfigurationTests {
    private struct Fixture {
        let directory: URL
        var config: URL { directory.appendingPathComponent("config") }
        init(_ files: [String: String]) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("far-ssh-config-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (path, contents) in files {
                let url = directory.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contents.utf8).write(to: url)
            }
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
        func importAlias(_ alias: String = "prod") throws -> NetworkConnection {
            try SSHConfiguration.importConnection(alias: alias, from: config, username: "local-user")
        }
    }

    @Test func respectsFirstValueCaseInsensitivePatternsAndNegation() throws {
        let fixture = try Fixture(["config": """
        # Values and Host patterns remain independent of resolved HostName.
        hOsT PROD? !prodX
          hOsTnAmE = %h.internal
          User "deploy"
          Port=2222
        Host prod*
          User ignored
          Port 3333
        Host * !prodX
          IdentityFile "%d/.ssh/%n-%r-%p" # comment
        Host *
          User fallback
        """])
        defer { fixture.remove() }
        let imported = try fixture.importAlias("PrOdA")
        #expect(imported.name == "PrOdA")
        #expect(imported.host == "PrOdA.internal")
        #expect(imported.username == "deploy")
        #expect(imported.port == 2222)
        #expect(imported.privateKeyPath == FileManager.default.homeDirectoryForCurrentUser.path + "/.ssh/PrOdA-deploy-2222")
        #expect(imported.sftpAuthenticationMode == .keyAgent)
        let excluded = try fixture.importAlias("prodX")
        #expect(excluded.host == "prodX")
        #expect(excluded.username == "ignored")
        #expect(excluded.privateKeyPath == nil)
    }

    @Test func includesAreConditionalLexicalAndDoNotLeakTheirHostSection() throws {
        let fixture = try Fixture([
            "config": """
            Host other
              Include missing-or-unsafe.conf
            Host prod
              Include "parts/*.conf"
              User parent-user
            Host *
              Port 22
            """,
            "parts/20-last.conf": "Host prod\n  Port 2202\nHost unrelated\n  User never\n",
            "parts/10-first.conf": "Host prod\n  Port 2201\n",
            "missing-or-unsafe.conf": "ProxyCommand touch never-executed\n"
        ])
        defer { fixture.remove() }
        let imported = try fixture.importAlias()
        #expect(imported.port == 2201)
        #expect(imported.username == "parent-user")
    }

    @Test func resolvesNestedJumpAliasesAndCommandLineAddressOverrides() throws {
        let fixture = try Fixture(["config": """
        Host prod
          HostName database.internal
          User database-user
          ProxyJump override@inner:2202
          ConnectTimeout 45
        Host inner
          HostName inner.internal
          User ignored-by-address
          Port 2200
          IdentityFile ~/.ssh/inner
          ProxyJump outer
        Host outer
          HostName outer.example.org
          User outer-user
          IdentityFile /keys/outer
        """])
        defer { fixture.remove() }
        let imported = try fixture.importAlias()
        #expect(imported.host == "database.internal")
        #expect(imported.username == "database-user")
        #expect(imported.timeoutSeconds == 45)
        #expect(imported.sftpJumpHosts == [
            SFTPJumpHost(host: "outer.example.org", username: "outer-user", privateKeyPath: "/keys/outer"),
            SFTPJumpHost(host: "inner.internal", port: 2202, username: "override", privateKeyPath: FileManager.default.homeDirectoryForCurrentUser.path + "/.ssh/inner")
        ])
    }

    @Test func supportsOrderedProxyJumpListURIAndBracketedIPv6() throws {
        let fixture = try Fixture(["config": """
        Host prod
          ProxyJump first@[2001:db8::1]:2201,ssh://second@gateway:2202
        Host gateway
          HostName gateway.example.org
        """])
        defer { fixture.remove() }
        #expect(try fixture.importAlias().sftpJumpHosts == [
            SFTPJumpHost(host: "2001:db8::1", port: 2201, username: "first"),
            SFTPJumpHost(host: "gateway.example.org", port: 2202, username: "second")
        ])
    }

    @Test func explicitJumpListsOverrideLaterGatewayRoutesAndAllowUnderscoreAliases() throws {
        let fixture = try Fixture(["config": """
        Host prod_alias
          HostName prod.example.org
          ProxyJump first_alias,second_alias
        Host first_alias
          HostName first.example.org
          ProxyJump outer
        Host second_alias
          HostName second.example.org
          ProxyJump must-not-be-used
          IdentityFile /keys/second
          IdentitiesOnly yes
        Host outer
          HostName outer.example.org
        """])
        defer { fixture.remove() }
        let imported = try fixture.importAlias("prod_alias")
        #expect(imported.host == "prod.example.org")
        #expect(imported.sftpJumpHosts.map(\.host) == ["outer.example.org", "first.example.org", "second.example.org"])
        #expect(imported.sftpJumpHosts.last?.privateKeyPath == "/keys/second")
        // An alias may contain underscores; the final server hostname may not.
        #expect(throws: (any Error).self) { try fixture.importAlias("undefined_alias") }
    }

    @Test func dangerousHooksAndUnrepresentedSecurityOrAuthenticationFailWithoutExecution() throws {
        let fixture = try Fixture(["config": ""])
        defer { fixture.remove() }
        let marker = fixture.directory.appendingPathComponent("must-not-exist")
        for directive in [
            "ProxyCommand touch \(marker.path)",
            "Match exec \"touch \(marker.path)\"",
            "LocalCommand touch \(marker.path)",
            "IdentityAgent /tmp/custom-agent", "IdentitiesOnly yes",
            "CertificateFile /keys/cert.pub", "UserKnownHostsFile /keys/known_hosts",
            "CanonicalizeHostname yes", "PreferredAuthentications password"
        ] {
            try Data(("Host prod\n  " + directive + "\n").utf8).write(to: fixture.config)
            #expect(throws: (any Error).self) { try fixture.importAlias() }
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
        try Data("Host ignored\n  ProxyCommand false\nHost prod\n  HostName safe.example.org\n".utf8).write(to: fixture.config)
        #expect(try fixture.importAlias().host == "safe.example.org")
    }

    @Test func keysAreLiteralDataAndUnsupportedExpansionFails() throws {
        let fixture = try Fixture(["config": "Host prod\n  IdentityFile \"/keys/key # $(touch never) ; literal\"\n"])
        defer { fixture.remove() }
        #expect(try fixture.importAlias().privateKeyPath == "/keys/key # $(touch never) ; literal")
        for value in ["${UNSET}/key", "%C/key", "~someone/key", "relative-key", "none"] {
            try Data(("Host prod\n  IdentityFile \"" + value + "\"\n").utf8).write(to: fixture.config)
            #expect(throws: (any Error).self) { try fixture.importAlias() }
        }
        try Data("Host prod\n  HostName -oProxyCommand=bad\n".utf8).write(to: fixture.config)
        #expect(throws: (any Error).self) { try fixture.importAlias() }
    }

    @Test func keyPathQuotesEscapesAndEmbeddedCommentCharactersFollowOpenSSH() throws {
        let fixture = try Fixture(["config": ""])
        defer { fixture.remove() }
        for (argument, expected) in [
            ("'/keys/key with spaces'", "/keys/key with spaces"),
            ("/keys/key#literal", "/keys/key#literal"),
            (#"/keys/key\ with\ spaces"#, "/keys/key with spaces"),
            (#""/keys/key\a""#, #"/keys/key\a"#),
            (#""/keys/key\"quoted""#, "/keys/key\"quoted")
        ] {
            try Data(("Host prod\n  IdentityFile " + argument + " # actual comment\n").utf8).write(to: fixture.config)
            #expect(try fixture.importAlias().privateKeyPath == expected)
        }
    }

    @Test func identityFileAccumulationIsNeverSilentlyDiscarded() throws {
        let fixture = try Fixture(["config": "Host prod\n  IdentityFile /keys/first\nHost *\n  IdentityFile /keys/second\n"])
        defer { fixture.remove() }
        #expect(throws: (any Error).self) { try fixture.importAlias() }
        try Data("Host prod\n  IdentityFile /keys/same\nHost *\n  IdentityFile /keys/same\n".utf8).write(to: fixture.config)
        #expect(try fixture.importAlias().privateKeyPath == "/keys/same")
        try Data("Host prod\n  IdentityFile /keys/first\n  IdentitiesOnly no\n".utf8).write(to: fixture.config)
        #expect(throws: (any Error).self) { try fixture.importAlias() }
    }

    @Test func commonKeychainSettingsAcceptOnlyEquivalentRuntimePolicies() throws {
        let fixture = try Fixture(["config": """
        Host prod
          HostName prod.example.org
          IdentityFile ~/.ssh/id_ed25519
          IdentitiesOnly yes
          UseKeychain yes
          AddKeysToAgent no
          ForwardAgent no
          PasswordAuthentication no
          PubkeyAuthentication yes
          CanonicalizeHostname no
          ServerAliveInterval 30
        """])
        defer { fixture.remove() }
        #expect(try fixture.importAlias().host == "prod.example.org")
        for directive in ["UseKeychain no", "AddKeysToAgent yes", "AddKeysToAgent confirm", "ForwardAgent yes", "PubkeyAuthentication no", "PasswordAuthentication yes"] {
            try Data(("Host prod\n  " + directive + "\n").utf8).write(to: fixture.config)
            #expect(throws: (any Error).self) { try fixture.importAlias() }
        }
    }

    @Test func rejectsIncludeCyclesAndCyclesThroughDifferentHostAliases() throws {
        let fixture = try Fixture(["config": "Include nested\n", "nested": "Include config\n"])
        defer { fixture.remove() }
        #expect(throws: SSHConfigurationError.includeCycle(fixture.config.resolvingSymlinksInPath().path)) { try fixture.importAlias() }
        try Data("Host prod\n  ProxyJump gateway\nHost gateway\n  ProxyJump prod\n".utf8).write(to: fixture.config)
        #expect(throws: SSHConfigurationError.jumpCycle("prod")) { try fixture.importAlias() }
        try Data("Host prod\n  HostName same.example.org\n  ProxyJump gateway\nHost gateway\n  HostName SAME.EXAMPLE.ORG\n".utf8).write(to: fixture.config)
        #expect(throws: SSHConfigurationError.jumpCycle("SAME.EXAMPLE.ORG")) { try fixture.importAlias() }
    }

    @Test func rejectsMalformedAddressesSyntaxAndResourceExhaustion() throws {
        let fixture = try Fixture(["config": ""])
        defer { fixture.remove() }
        for body in [
            "Port 0", "Port +22", "Port 65536", "ProxyJump ,gateway", "ProxyJump user@",
            "ProxyJump [::1]:bad", "ProxyJump a,b,c,d,e", "IdentityFile \"unclosed", "User \"bad user\""
        ] {
            try Data(("Host prod\n  " + body + "\n").utf8).write(to: fixture.config)
            #expect(throws: (any Error).self) { try fixture.importAlias() }
        }
        try Data(repeating: 32, count: 1_048_577).write(to: fixture.config)
        #expect(throws: SSHConfigurationError.limitExceeded("общий размер не более 1 МиБ")) { try fixture.importAlias() }
        try Data([0xff, 0xfe]).write(to: fixture.config)
        #expect(throws: (any Error).self) { try fixture.importAlias() }
    }

    @Test func repetitiveHostWildcardsRemainBoundedAndNegativeOnlyDoesNotMatch() throws {
        let repetitive = String(repeating: "*a", count: 1000) + "z"
        let fixture = try Fixture(["config": "Host \(repetitive)\n  User wrong\nHost !other\n  User also-wrong\nHost *\n  User fallback\n"])
        defer { fixture.remove() }
        #expect(try fixture.importAlias(String(repeating: "a", count: 250)).username == "fallback")
    }
}
