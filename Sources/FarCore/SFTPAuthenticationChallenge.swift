import Foundation

/// The configured, host-key-checked endpoint, never a loopback tunnel address.
public struct SFTPAuthenticationEndpoint: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let username: String
    public let jumpHostIndex: Int?
    public init(host: String, port: Int, username: String, jumpHostIndex: Int? = nil) {
        self.host = host; self.port = port; self.username = username; self.jumpHostIndex = jumpHostIndex
    }
}

public typealias SFTPAuthenticationHandler = @Sendable (SFTPAuthenticationChallenge) -> Void

/// One round of authentication. Responses are consumed once by the owning process.
public final class SFTPAuthenticationChallenge: @unchecked Sendable {
    public let endpoint: SFTPAuthenticationEndpoint
    public let prompt: String
    private let lock = NSLock()
    private var pending = true
    private var result: Result<String, SFTPError>?
    private var callbacks: [@Sendable () -> Void] = []
    public init(endpoint: SFTPAuthenticationEndpoint, prompt: String) {
        self.endpoint = endpoint; self.prompt = prompt
    }
    public var isPending: Bool { lock.lock(); defer { lock.unlock() }; return pending }
    public func respond(_ response: String?) throws {
        if let response {
            guard response.utf8.count <= 1023, !response.contains("\0"), !response.contains(where: { $0.isNewline }) else {
                throw SFTPError.invalidPassword
            }
        }
        lock.lock()
        guard pending else { lock.unlock(); throw SFTPError.cancelled }
        pending = false
        result = response.map { .success($0) } ?? .failure(.cancelled)
        let completions = callbacks; callbacks.removeAll(); lock.unlock()
        completions.forEach { $0() }
    }
    public func whenFinished(_ callback: @escaping @Sendable () -> Void) {
        lock.lock()
        if pending { callbacks.append(callback); lock.unlock() }
        else { lock.unlock(); callback() }
    }
    func takeResult() -> Result<String, SFTPError>? {
        lock.lock(); defer { lock.unlock() }
        let value = result; result = nil; return value
    }
    func finish() {
        lock.lock(); pending = false; result = nil
        let completions = callbacks; callbacks.removeAll(); lock.unlock()
        completions.forEach { $0() }
    }
}
