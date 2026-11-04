import AppKit
import FarCore

/// Owns each request separately, including requests from independent host-key probes.
/// Background SSH processes never wait on the main thread or share an answer field.
@MainActor
final class SSHAuthenticationPresenter {
    private var windows: [ObjectIdentifier: SSHAuthenticationWindow] = [:]

    nonisolated func handle(_ challenge: SFTPAuthenticationChallenge) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { try? challenge.respond(nil); return }
            self.present(challenge)
        }
    }

    private func present(_ challenge: SFTPAuthenticationChallenge) {
        guard challenge.isPending else { return }
        let identifier = ObjectIdentifier(challenge)
        guard windows[identifier] == nil else { return }
        let controller = SSHAuthenticationWindow(challenge: challenge)
        guard challenge.isPending else { return }
        controller.onFinished = { [weak self] in self?.windows.removeValue(forKey: identifier) }
        windows[identifier] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func cancelAll() {
        let pending = Array(windows.values)
        pending.forEach { $0.cancelAuthentication() }
    }

    deinit {
        let pending = Array(windows.values)
        pending.forEach { try? $0.challenge.respond(nil) }
        DispatchQueue.main.async { pending.forEach { $0.dismissIfFinished() } }
    }
}

@MainActor
final class SSHAuthenticationWindow: FileToolsWindowController {
    nonisolated let challenge: SFTPAuthenticationChallenge
    var onFinished: (() -> Void)?
    private let endpoint = NSTextField(wrappingLabelWithString: "")
    private let serverPrompt = NSTextView()
    private let answer = NSSecureTextField()
    private var finished = false
    private lazy var continueButton = button(L10n.text("Продолжить"), #selector(submit))

    init(challenge: SFTPAuthenticationChallenge) {
        self.challenge = challenge
        super.init(title: L10n.text("Вход SSH / MFA"), width: 650, height: 500)
        window?.minSize = NSSize(width: 600, height: 500)
        let target = challenge.endpoint
        let role = target.jumpHostIndex.map { L10n.text("Промежуточный SSH-сервер") + " \($0 + 1)" } ?? L10n.text("Целевой SSH-сервер")
        endpoint.stringValue = role + "\n\(target.username)@\(target.host):\(target.port)"
        endpoint.font = .systemFont(ofSize: 15, weight: .semibold)
        endpoint.isSelectable = true
        serverPrompt.isEditable = false; serverPrompt.isRichText = false
        serverPrompt.isAutomaticLinkDetectionEnabled = false
        serverPrompt.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        serverPrompt.string = challenge.prompt
        serverPrompt.textContainerInset = NSSize(width: 8, height: 8)
        serverPrompt.isVerticallyResizable = true; serverPrompt.autoresizingMask = [.width]
        serverPrompt.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(); scroll.documentView = serverPrompt; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        answer.placeholderString = L10n.text("Пароль, код или ответ на запрос")
        answer.target = self; answer.action = #selector(submit)
        continueButton.keyEquivalent = "\r"
        let cancelButton = button(L10n.text("Отмена"), #selector(cancelAuthentication)); cancelButton.keyEquivalent = "\u{1b}"
        let hint = NSTextField(wrappingLabelWithString: L10n.text("Ответ используется только для входа на указанный сервер и не сохраняется. Время ввода входит в таймаут операции. Отмена прерывает подключение."))
        content([endpoint, NSTextField(labelWithString: L10n.text("Запрос SSH (может содержать текст сервера):")), scroll, answer, hint, status, row([cancelButton, NSView(), continueButton])])
        window?.initialFirstResponder = answer
        challenge.whenFinished { [weak self] in
            DispatchQueue.main.async { self?.dismissIfFinished() }
        }
        dismissIfFinished()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        guard !finished, challenge.isPending else { dismissIfFinished(); return }
        super.showWindow(sender)
    }
    @objc private func submit() {
        guard !finished, challenge.isPending else { dismissIfFinished(); return }
        do {
            try challenge.respond(answer.stringValue)
            dismissIfFinished()
        } catch {
            answer.stringValue = ""
            if challenge.isPending { status.stringValue = error.localizedDescription }
            else { dismissIfFinished() }
        }
    }
    @objc func cancelAuthentication() {
        try? challenge.respond(nil)
        dismissIfFinished()
    }
    func dismissIfFinished() {
        guard !challenge.isPending, !finished else { return }
        finished = true; window?.makeFirstResponder(nil); answer.stringValue = ""; answer.isEnabled = false; continueButton.isEnabled = false
        close(); onFinished?(); onFinished = nil
    }
    override func windowShouldClose(_ sender: NSWindow) -> Bool { cancelAuthentication(); return false }

    /// Real AppKit controls with synthetic requests; no SSH process or stored credentials.
    static func runUISmokeChecks() throws -> [String] {
        let first = SFTPAuthenticationChallenge(endpoint: .init(host: "jump.fixture", port: 2202, username: "jump-user", jumpHostIndex: 1), prompt: "OTP <fixture>:\nhttps://untrusted.fixture")
        let second = SFTPAuthenticationChallenge(endpoint: .init(host: "target.fixture", port: 22, username: "target-user"), prompt: "Password:")
        let firstWindow = SSHAuthenticationWindow(challenge: first), secondWindow = SSHAuthenticationWindow(challenge: second)
        guard firstWindow.endpoint.stringValue.contains("jump-user@jump.fixture:2202"),
              secondWindow.endpoint.stringValue.contains("target-user@target.fixture:22"),
              firstWindow.serverPrompt.string == first.prompt, !firstWindow.serverPrompt.isEditable,
              !firstWindow.serverPrompt.isRichText else { throw NetworkError.io("SSH prompts must display their own endpoint and literal untrusted text") }
        firstWindow.answer.stringValue = "fixture-answer"; firstWindow.cancelAuthentication()
        guard !first.isPending, second.isPending, firstWindow.answer.stringValue.isEmpty, firstWindow.finished else {
            throw NetworkError.io("Cancel must resolve only its own SSH request and erase the answer")
        }
        secondWindow.answer.stringValue = "stale-fixture"
        try second.respond(nil) // Simulates timeout / process completion before a queued UI response.
        let deadline = Date().addingTimeInterval(0.2)
        while !secondWindow.finished && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        secondWindow.submit()
        guard secondWindow.finished, secondWindow.answer.stringValue.isEmpty, !secondWindow.answer.isEnabled else {
            throw NetworkError.io("A completed SSH request must close and discard stale input")
        }
        let resolved = SFTPAuthenticationChallenge(endpoint: .init(host: "finished.fixture", port: 22, username: "fixture"), prompt: "Expired:")
        try resolved.respond(nil)
        let staleWindow = SSHAuthenticationWindow(challenge: resolved)
        staleWindow.showWindow(nil)
        guard staleWindow.window?.isVisible != true, staleWindow.finished else { throw NetworkError.io("An already finished SSH request must never open a stale dialog") }
        return ["SSH requests display independent verified endpoints and literal server prompts", "Cancel and request completion erase input and prevent stale answers"]
    }
}
