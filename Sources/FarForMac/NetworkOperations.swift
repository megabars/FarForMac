import AppKit
import FarCore

private final class NetworkProgressMailbox: @unchecked Sendable {
    private let lock = NSLock(); private var value: NetworkProgress?
    func publish(_ value: NetworkProgress) { lock.lock(); self.value = value; lock.unlock() }
    func take() -> NetworkProgress? { lock.lock(); defer { lock.unlock() }; let result = value; value = nil; return result }
}
@MainActor private final class NetworkProgressWindow: FileToolsWindowController {
    private let token: TransferCancellation, mailbox: NetworkProgressMailbox
    private let bar = NSProgressIndicator(); private var timer: Timer?
    init(title: String, token: TransferCancellation, mailbox: NetworkProgressMailbox) {
        self.token = token; self.mailbox = mailbox
        super.init(title: title, width: 620, height: 230)
        bar.style = .bar; bar.isIndeterminate = true; bar.startAnimation(nil)
        let cancel = button("Отменить", #selector(cancelWork)); cancel.keyEquivalent = "\u{1b}"
        content([status, bar, NSTextField(wrappingLabelWithString: "При отмене завершённые объекты сохраняются. Дождитесь остановки и очистки временных файлов."), NSView(), row([NSView(), cancel])])
        status.stringValue = "Соединение с сервером…"; isWorking = true; hasPendingMutation = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
    }
    required init?(coder: NSCoder) { fatalError() }
    private func update() {
        guard let progress = mailbox.take() else { return }
        status.stringValue = progress.path + "\n" + ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file)
        if progress.totalBytes > 0 { bar.isIndeterminate = false; bar.maxValue = Double(progress.totalBytes); bar.doubleValue = Double(progress.completedBytes) }
    }
    @objc private func cancelWork() { token.cancel(); status.stringValue = "Отмена…" }
    func finish() { timer?.invalidate(); timer = nil; isWorking = false; hasPendingMutation = false; close() }
    override func windowShouldClose(_ sender: NSWindow) -> Bool { if isWorking { cancelWork(); return false }; return true }
}
@MainActor final class NetworkOperationController {
    private(set) var isWorking = false
    private var token: TransferCancellation?
    private var window: NetworkProgressWindow?
    func cancel() { token?.cancel() }
    func run<Value>(title: String, work: @escaping (TransferCancellation, @escaping (NetworkProgress) -> Void) throws -> Value,
                    completion: @escaping (Result<Value, Error>) -> Void) {
        guard !isWorking else { completion(.failure(NetworkError.io("Дождитесь текущей сетевой операции."))); return }
        let token = TransferCancellation(), mailbox = NetworkProgressMailbox()
        self.token = token; isWorking = true
        let window = NetworkProgressWindow(title: title, token: token, mailbox: mailbox); self.window = window; window.showWindow(nil)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try work(token, { mailbox.publish($0) }) }
            DispatchQueue.main.async { [self] in
                self.window?.finish(); self.window = nil; self.token = nil; self.isWorking = false
                completion(result)
            }
        }
    }
}
