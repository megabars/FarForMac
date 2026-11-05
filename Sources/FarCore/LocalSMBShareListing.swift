import Foundation

/// Run the system SMB client directly in an isolated controlling terminal.
/// The password is sent only in response to the client's non-echoing prompt.
@MainActor public final class LocalSMBShareListing {
    private static let maximumOutput = 2 * 1024 * 1024
    private var session: TerminalSession?
    private var timeout: DispatchWorkItem?
    private var request: UUID?
    private var output = Data()
    private var awaitingPassword: String?
    private var completion: ((Result<[LocalSMBShare], Error>) -> Void)?

    public init() {}

    public func start(server: LocalSMBServer, account: LocalSMBAccount? = nil,
                      completion: @escaping (Result<[LocalSMBShare], Error>) -> Void) {
        stop()
        let request = UUID()
        self.request = request
        self.completion = completion
        do {
            let url = try server.url(account: account)
            let arguments = account == nil ? ["view", "-N", "-G"] : ["view", "-f"]
            let session = TerminalSession(configuration: .init(directory: URL(fileURLWithPath: "/"), shell: "/usr/bin/smbutil",
                shellArguments: arguments + [String(url.absoluteString.dropFirst("smb:".count))],
                environmentOverrides: ["LC_ALL": "C"]), onOutput: { [weak self] data in
                    guard let self, self.request == request else { return }
                    self.receive(data)
                }, onExit: { [weak self] exit in
                    guard let self, self.request == request else { return }
                    self.finish(Result {
                        guard exit.succeeded else { throw LocalSMBError.listingFailed }
                        return try Self.parse(self.output)
                    })
                })
            self.session = session
            awaitingPassword = account?.password
            try session.start()
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.request == request else { return }
                self.finish(.failure(LocalSMBError.timedOut))
            }
            self.timeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: timeout)
        } catch {
            finish(.failure(LocalSMBError.listingFailed))
        }
    }

    public func stop() {
        request = nil
        completion = nil
        timeout?.cancel()
        timeout = nil
        awaitingPassword = nil
        output.removeAll()
        session?.forceStop()
        session = nil
    }

    private func receive(_ data: Data) {
        guard data.count <= Self.maximumOutput - output.count else {
            finish(.failure(LocalSMBError.listingFormat))
            return
        }
        output.append(data)
        guard let password = awaitingPassword, Self.isPasswordPrompt(output) else { return }
        awaitingPassword = nil
        output.removeAll()
        do { try session?.send(password + "\n") }
        catch { finish(.failure(LocalSMBError.listingFailed)) }
    }

    private func finish(_ result: Result<[LocalSMBShare], Error>) {
        let completion = self.completion
        stop()
        completion?(result)
    }

    nonisolated static func isPasswordPrompt(_ data: Data) -> Bool {
        let prefix = "Password for "
        guard let line = String(data: data, encoding: .utf8), line.hasPrefix(prefix), line.hasSuffix(": "),
              line.utf8.count > prefix.utf8.count + 2, line.utf8.count <= 127 else { return false }
        return !line.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    nonisolated static func parse(_ data: Data) throws -> [LocalSMBShare] {
        // smbutil's printf columns are measured in bytes, even for UTF-8 names.
        let lines = data.split(separator: 10).map { $0.last == 13 ? $0.dropLast() : $0 }.filter { !$0.isEmpty }
        guard lines.count >= 3,
              String(decoding: lines[0], as: UTF8.self).split(whereSeparator: \.isWhitespace) == ["Share", "Type", "Comments"],
              lines[1].allSatisfy({ $0 == 45 }),
              let count = String(decoding: lines[lines.count - 1], as: UTF8.self).split(separator: " ").first.flatMap({ Int($0) }),
              String(decoding: lines[lines.count - 1], as: UTF8.self) == "\(count) shares listed",
              count == lines.count - 3 else { throw LocalSMBError.listingFormat }
        let types = ["Disk", "Printer", "Pipe", "Comm", "Unknown"]
        var shares: [LocalSMBShare] = []
        var names = Set<String>()
        for row in lines.dropFirst(2).dropLast() {
            guard row.count >= 56 else { throw LocalSMBError.listingFormat }
            // The printed name can be longer than the minimum width of 48.
            var candidates = (48...min(240, row.count - 8)).lazy.compactMap { offset -> (Int, String)? in
                let field = row.dropFirst(offset).prefix(8)
                return types.first(where: { type in field.elementsEqual((type + String(repeating: " ", count: 8 - type.count)).utf8) })
                    .map { (offset, $0) }
            }.makeIterator()
            guard let (offset, type) = candidates.next(), offset == 48 || candidates.next() == nil,
                  let rawName = String(bytes: row.prefix(offset), encoding: .utf8) else { throw LocalSMBError.listingFormat }
            let name = String(rawName.reversed().drop(while: { $0 == " " }).reversed())
            guard type == "Disk", !name.hasSuffix("$"), LocalSMBServer.validShareName(name),
                  names.insert(name.lowercased()).inserted else { continue }
            shares.append(LocalSMBShare(name: name))
        }
        return shares.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
