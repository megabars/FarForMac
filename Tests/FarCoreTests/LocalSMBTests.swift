import Foundation
import Testing
@testable import FarCore

struct LocalSMBTests {
    @Test func addressHasOnlyHostAndOptionalPort() throws {
        let server = try LocalSMBServer(address: "  \\\\files.local  ")
        #expect(server.host == "files.local")
        #expect(server.port == nil)
        #expect(server.matches(host: "FILES.local.", port: 445))
        #expect(!server.matches(host: "files.local", port: 1445))
        let explicit = try LocalSMBServer(address: "smb://[fd00::1]:1445/")
        #expect(explicit.displayAddress == "[fd00::1]:1445")
        #expect(try LocalSMBServer(address: "fd00::1").displayAddress == "[fd00::1]")
        for invalid in ["", "sftp://host", "smb://user:pass@host", "server/share", "host?query", "host#fragment",
                        "host%2fnext", "bad host", "host:0", "host:65536"] {
            #expect(throws: LocalSMBError.invalidServer) { try LocalSMBServer(address: invalid) }
        }
    }

    @Test func credentialsAndShareDoNotChangeServerOrLeakPasswordIntoURL() throws {
        let server = try LocalSMBServer(address: "files.local")
        let account = try LocalSMBAccount(user: "OFFICE\\name:@%", password: "private:$@")
        let url = try server.url(share: "Фото #1%?", account: account)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "files.local")
        #expect(components.path == "/Фото #1%?")
        #expect(components.password == nil)
        #expect(components.percentEncodedUser == "OFFICE;name%3A%40%25")
        #expect(!url.absoluteString.contains(account.password))
        for invalid in ["..", "a/b", "a\\b", "name\nnext"] {
            #expect(throws: LocalSMBError.invalidShare) { try server.url(share: invalid) }
        }
        #expect(throws: LocalSMBError.invalidAccount) { try LocalSMBAccount(user: "name", password: "first\nnext") }
        #expect(throws: LocalSMBError.invalidAccount) { try LocalSMBAccount(user: "name", password: String(repeating: "x", count: 129)) }
    }

    @Test func smbutilRowsKeepUnicodeAndSpacesAndFilterNonDiskEntries() throws {
        let longName = String(repeating: "ф", count: 30)
        let data = listing([("Public Files", "Disk", "Shared files"), ("Фото семьи", "Disk", ""),
                            ("print", "Printer", ""), ("IPC$", "Pipe", ""), ("Admin$", "Disk", ""),
                            (longName, "Disk", ""), ("public files", "Disk", "duplicate")])
        let result = try LocalSMBShareListing.parse(data)
        #expect(Set(result.map(\.name)) == Set(["Public Files", "Фото семьи", longName]))
        #expect(try LocalSMBShareListing.parse(listing([])).isEmpty)
    }

    @Test func rejectsPartialListingAndDoesNotMistakeOutputForPasswordPrompt() throws {
        #expect(throws: LocalSMBError.listingFormat) {
            try LocalSMBShareListing.parse(Data("Share Type Comments\n-----\n5 shares listed\n".utf8))
        }
        #expect(LocalSMBShareListing.isPasswordPrompt(Data("Password for files.local: ".utf8)))
        #expect(!LocalSMBShareListing.isPasswordPrompt(Data("Password for files.local:".utf8)))
        #expect(!LocalSMBShareListing.isPasswordPrompt(Data("Share Type Comments\nPassword for files.local: ".utf8)))
    }

    private func listing(_ rows: [(name: String, type: String, comment: String)]) -> Data {
        func pad(_ value: String, to size: Int) -> String {
            value + String(repeating: " ", count: max(0, size - value.utf8.count))
        }
        let header = "Share                                           Type    Comments\r\n-------------------------------\r\n"
        let body = rows.map { pad($0.name, to: 48) + pad($0.type, to: 8) + $0.comment + "\r\n" }.joined()
        return Data((header + body + "\r\n\(rows.count) shares listed\r\n").utf8)
    }
}
