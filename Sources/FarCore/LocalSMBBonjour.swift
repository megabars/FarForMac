import Foundation
import Network

public struct LocalSMBAdvertisement: Hashable, Sendable {
    public let name: String
    let type: String
    let domain: String
}

@MainActor public final class LocalSMBBonjour {
    private var browser: NWBrowser?

    public init() {}

    public func start(onResults: @escaping @MainActor ([LocalSMBAdvertisement]) -> Void,
                      onProblem: @escaping @MainActor (String) -> Void) {
        stop()
        let browser = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: "local."), using: .tcp)
        self.browser = browser
        // NWBrowser delivers both handlers on the main queue passed to start.
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            MainActor.assumeIsolated {
                guard let self, let browser, self.browser === browser else { return }
                switch state {
                case .ready:
                    onProblem("")
                case .failed(let error), .waiting(let error):
                    if case .dns(let code) = error, code == -65570 || code == -65555 {
                        onProblem("Разрешите FarForMac доступ к локальной сети в настройках macOS.")
                    } else {
                        onProblem("Обнаружение SMB-серверов недоступно. Можно указать адрес сервера.")
                    }
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            MainActor.assumeIsolated {
                guard let self, let browser, self.browser === browser else { return }
                let servers = Set(results.compactMap { result -> LocalSMBAdvertisement? in
                    guard case let .service(name, type, domain, _) = result.endpoint else { return nil }
                    return LocalSMBAdvertisement(name: name, type: type, domain: domain)
                })
                onResults(servers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
            }
        }
        browser.start(queue: .main)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    deinit { browser?.cancel() }
}

/// Resolves a selected Bonjour service without making an SMB connection to it.
@MainActor public final class LocalSMBResolver: NSObject, @preconcurrency NetServiceDelegate {
    private var service: NetService?
    private var completion: ((Result<LocalSMBServer, Error>) -> Void)?

    public func resolve(_ advertisement: LocalSMBAdvertisement,
                        completion: @escaping (Result<LocalSMBServer, Error>) -> Void) {
        stop()
        let service = NetService(domain: advertisement.domain, type: advertisement.type, name: advertisement.name)
        self.service = service
        self.completion = completion
        service.delegate = self
        service.resolve(withTimeout: 6)
    }

    public func stop() {
        service?.delegate = nil
        service?.stop()
        service = nil
        completion = nil
    }

    public func netServiceDidResolveAddress(_ sender: NetService) {
        guard service === sender else { return }
        finish(Result {
            guard let host = sender.hostName else { throw LocalSMBError.cannotResolve }
            return try LocalSMBServer(host: host, port: sender.port)
        })
    }

    public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        guard service === sender else { return }
        finish(.failure(LocalSMBError.cannotResolve))
    }

    private func finish(_ result: Result<LocalSMBServer, Error>) {
        let completion = self.completion
        stop()
        completion?(result)
    }
}
