import CoreFoundation
import Foundation
import NetFS

@MainActor public final class LocalSMBMountRequest {
    private var request: AsyncRequestID?
    private var token: UUID?

    public init() {}

    public func start(server: LocalSMBServer, share: LocalSMBShare, account: LocalSMBAccount? = nil,
                      completion: @escaping (Result<URL, Error>) -> Void) {
        stop()
        let url: URL
        do { url = try server.url(share: share.name) }
        catch { completion(.failure(error)); return }

        if account == nil, let existing = LocalSMBMount.matching(server: server, share: share).first {
            completion(.success(existing.url))
            return
        }
        var keyCallbacks = kCFTypeDictionaryKeyCallBacks
        var valueCallbacks = kCFTypeDictionaryValueCallBacks
        let options = CFDictionaryCreateMutable(nil, 0, &keyCallbacks, &valueCallbacks)!
        let uiKey = "UIOption" as CFString
        let uiValue = (account == nil ? "AllowUI" : "NoUI") as CFString
        CFDictionarySetValue(options, Unmanaged.passUnretained(uiKey).toOpaque(), Unmanaged.passUnretained(uiValue).toOpaque())
        func enable(_ name: String) {
            let key = name as CFString
            CFDictionarySetValue(options, Unmanaged.passUnretained(key).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        enable("AllowLoopback")
        if account != nil { enable("ForceNewSession") }

        let token = UUID()
        self.token = token
        var id: AsyncRequestID?
        let status = NetFSMountURLAsync(url as CFURL, nil, account.map { $0.user as CFString },
                                        account.map { $0.password as CFString }, options, nil, &id, .main) {
            [weak self] status, _, paths in
            guard let self, self.token == token else { return }
            self.token = nil
            self.request = nil
            if status == -128 {
                completion(.failure(CancellationError()))
            } else if status != 0 {
                completion(.failure(LocalSMBError.mountFailed(status)))
            } else if let paths, let path = (paths as NSArray).firstObject as? String, path.hasPrefix("/") {
                completion(.success(URL(fileURLWithPath: path, isDirectory: true)))
            } else {
                completion(.failure(LocalSMBError.mountMissing))
            }
        }
        if status == 0 {
            request = id
        } else {
            self.token = nil
            completion(.failure(status == -128 ? CancellationError() : LocalSMBError.mountFailed(status)))
        }
    }

    public func stop() {
        token = nil
        if let request { NetFSMountURLCancel(request) }
        request = nil
    }

    deinit { if let request { NetFSMountURLCancel(request) } }
}
