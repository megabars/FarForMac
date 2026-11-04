import Foundation
import Darwin

/// Per-process askpass transport. No answer is placed in argv, environment, or a regular file.
/// Only the process polling thread accesses bridge state; the challenge itself is synchronized.
final class SFTPInteractivePrompt {
    let directory: URL
    let requestURL: URL
    let responseURL: URL
    let helperURL: URL
    private let endpoint: SFTPAuthenticationEndpoint
    private let handler: SFTPAuthenticationHandler?
    private var requestFD: Int32 = -1
    private var responseFD: Int32 = -1
    private var buffer = Data()
    private var challenge: SFTPAuthenticationChallenge?
    private var rounds = 0
    private var stopped = false
    var environment: [String: String] {
        ["SSH_ASKPASS": helperURL.path, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": "farmac:0",
         "FARMAC_SFTP_REQUEST_FIFO": requestURL.path, "FARMAC_SFTP_RESPONSE_FIFO": responseURL.path]
    }
    init(endpoint: SFTPAuthenticationEndpoint, handler: SFTPAuthenticationHandler?) throws {
        self.endpoint = endpoint; self.handler = handler
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("farmac-interactive-" + UUID().uuidString)
        requestURL = directory.appendingPathComponent("request")
        responseURL = directory.appendingPathComponent("response")
        helperURL = directory.appendingPathComponent("askpass")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            guard mkfifo(requestURL.path, 0o600) == 0, mkfifo(responseURL.path, 0o600) == 0 else { throw POSIXError(.EIO) }
            let helper = """
            #!/bin/sh -p
            [ -z "${SSH_ASKPASS_PROMPT:-}" ] || exit 1
            [ "$#" -eq 1 ] || exit 1
            [ "${#1}" -le 4096 ] || exit 1
            printf '%s\\0' "$1" > "$FARMAC_SFTP_REQUEST_FIFO" || exit 1
            IFS= read -r answer < "$FARMAC_SFTP_RESPONSE_FIFO" || exit 1
            case "$answer" in
                1*) printf '%s\\n' "${answer#1}" ;;
                *) exit 1 ;;
            esac
            """ + "\n"
            try Data(helper.utf8).write(to: helperURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperURL.path)
            requestFD = open(requestURL.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
            responseFD = open(responseURL.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
            guard requestFD >= 0, responseFD >= 0 else { throw POSIXError(.EIO) }
            _ = fcntl(responseFD, F_SETNOSIGPIPE, 1)
        } catch { stop(); throw error }
    }
    static func displayPrompt(_ data: Data) throws -> String {
        guard data.count <= 4096, let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw SFTPError.unsupported("Сервер прислал некорректный запрос аутентификации SSH.")
        }
        // Remove terminal escapes, other controls and bidi overrides from untrusted server text.
        return String(String.UnicodeScalarView(text.unicodeScalars.filter {
            ($0.value >= 32 && $0.value != 127 && !CharacterSet.controlCharacters.contains($0) &&
             !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value)) || $0 == "\n" || $0 == "\t"
        }))
    }
    func poll() throws {
        guard !stopped else { return }
        if let result = challenge?.takeResult() {
            challenge = nil
            switch result {
            case .success(let response): try send(response)
            case .failure(let error): throw error
            }
        }
        var bytes = [UInt8](repeating: 0, count: 4097)
        while true {
            let count = Darwin.read(requestFD, &bytes, bytes.count)
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN { break }
                throw SFTPError.transport("Ошибка запроса аутентификации SSH.")
            }
            if count == 0 { break }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= 4097 else { throw SFTPError.unsupported("Слишком длинный запрос аутентификации SSH.") }
        }
        if !buffer.contains(0), buffer.count > 4096 {
            throw SFTPError.unsupported("Слишком длинный запрос аутентификации SSH.")
        }
        if let end = buffer.firstIndex(of: 0) {
            guard challenge == nil, end == buffer.count - 1, rounds < 16 else {
                throw SFTPError.unsupported("Превышен лимит запросов аутентификации SSH.")
            }
            let prompt = try Self.displayPrompt(Data(buffer.prefix(upTo: end)))
            buffer.removeAll(); rounds += 1
            guard let handler else { throw SFTPError.unsupported("Для интерактивного входа SSH нужен обработчик запроса пароля или кода подтверждения.") }
            let request = SFTPAuthenticationChallenge(endpoint: endpoint, prompt: prompt)
            challenge = request
            DispatchQueue.global(qos: .userInitiated).async { handler(request) }
        }
    }
    private func send(_ response: String) throws {
        var bytes = [UInt8]("1".utf8) + Array(response.utf8) + [10]
        defer { _ = bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let count = bytes.withUnsafeBytes { Darwin.write(responseFD, $0.baseAddress!, $0.count) }
        guard count == bytes.count else { throw SFTPError.transport("Ошибка ответа аутентификации SSH.") }
    }
    func stop() {
        guard !stopped else { return }; stopped = true
        challenge?.finish(); challenge = nil; buffer.removeAll()
        // Release an already running helper before closing/unlinking its FIFOs.
        if responseFD >= 0 { _ = Darwin.write(responseFD, "0\n", 2) }
        try? FileManager.default.removeItem(at: directory)
        if requestFD >= 0 { Darwin.close(requestFD); requestFD = -1 }
        if responseFD >= 0 { Darwin.close(responseFD); responseFD = -1 }
    }
    deinit { stop() }
}
