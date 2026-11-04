import AppKit
import FarCore

/// Explicit, editable connection order. Each endpoint carries its own authentication mode; secrets are requested only during connection.
@MainActor
final class SFTPJumpHostsWindow: FileToolsWindowController {
    var onApply: (([SFTPJumpHost]) -> Void)?
    var onClose: (() -> Void)?
    private let hosts = (0..<4).map { _ in NSTextField() }
    private let ports = (0..<4).map { _ in NSTextField(string: "22") }
    private let users = (0..<4).map { _ in NSTextField(string: NSUserName()) }
    private let authentication = (0..<4).map { _ in NSPopUpButton() }
    private let keys = (0..<4).map { _ in NSTextField() }

    init(hosts values: [SFTPJumpHost]) {
        super.init(title: L10n.text("Промежуточные SSH-серверы"), width: 1120, height: 390)
        window?.minSize = NSSize(width: 1120, height: 390)
        let titles = ["№", "Сервер", "Порт", "Пользователь", "Способ входа SFTP", "Закрытый SSH-ключ"]
        var rows: [[NSView]] = [titles.map { NSTextField(labelWithString: L10n.text($0)) }]
        for index in 0..<4 {
            authentication[index].addItems(withTitles: [L10n.text("SSH-ключ / agent"), L10n.text("Пароль"), L10n.text("Интерактивный / MFA")])
            authentication[index].tag = index; authentication[index].target = self
            authentication[index].action = #selector(authenticationChanged(_:))
            hosts[index].placeholderString = "jump.example.org"
            keys[index].placeholderString = L10n.text("Пусто — SSH agent / стандартные ключи")
            if index < values.count {
                let value = values[index]
                hosts[index].stringValue = value.host; ports[index].stringValue = String(value.port)
                users[index].stringValue = value.username; keys[index].stringValue = value.privateKeyPath ?? ""
                switch value.authenticationMode { case .keyAgent: authentication[index].selectItem(at: 0); case .password: authentication[index].selectItem(at: 1); case .interactive: authentication[index].selectItem(at: 2) }
            }
            authenticationChanged(authentication[index])
            rows.append([NSTextField(labelWithString: String(index + 1)), hosts[index], ports[index], users[index], authentication[index], keys[index]])
        }
        let grid = NSGridView(views: rows); grid.rowSpacing = 10; grid.columnSpacing = 10
        for (index, width) in [(0, 24.0), (1, 210.0), (2, 55.0), (3, 145.0)] { grid.column(at: index).width = width }
        let note = NSTextField(wrappingLabelWithString: L10n.text("Переходы выполняются сверху вниз, затем — вход на целевой сервер. Оставьте неиспользуемые строки пустыми. Для каждого сервера выберите способ входа. Пароли и ответы MFA запрашиваются при подключении и не сохраняются. Ключ каждого сервера проверяется отдельно."))
        content([note, grid, status, NSView(), row([button(L10n.text("Отмена"), #selector(cancel)), NSView(), button(L10n.text("Применить"), #selector(apply))])])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func authenticationChanged(_ sender: NSPopUpButton) {
        keys[sender.tag].isEnabled = sender.indexOfSelectedItem != 1
    }
    @objc private func apply() {
        do {
            var result: [SFTPJumpHost] = []
            for index in 0..<4 {
                let host = hosts[index].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = keys[index].stringValue
                if host.isEmpty {
                    guard key.isEmpty else { throw NetworkError.invalidConnection(L10n.text("Укажите сервер для строки с SSH-ключом.")) }
                    continue
                }
                guard let port = Int(ports[index].stringValue) else { throw NetworkError.invalidConnection(L10n.text("Порт должен быть числом.")) }
                let mode: SFTPAuthenticationMode = authentication[index].indexOfSelectedItem == 1 ? .password : (authentication[index].indexOfSelectedItem == 2 ? .interactive : .keyAgent)
                let identity = key.isEmpty || mode == .password ? nil : (key as NSString).expandingTildeInPath
                let jump = SFTPJumpHost(host: host, port: port, username: users[index].stringValue, privateKeyPath: identity, authenticationMode: mode)
                // Validate each row in jump position, including the stricter jump-user rules.
                // A distinct port keeps the synthetic target outside this row's endpoint.
                try NetworkConnection(kind: .sftp, host: host, port: port == 22 ? 23 : 22, username: "validation", sftpJumpHosts: [jump]).validate()
                guard !result.contains(where: { $0.host.caseInsensitiveCompare(host) == .orderedSame && $0.port == port }) else {
                    throw NetworkError.invalidConnection(L10n.text("Повторяющиеся серверы в цепочке запрещены."))
                }
                result.append(jump)
            }
            onApply?(result); finish()
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func cancel() { finish() }
    private func finish() {
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        close(); onClose?()
    }
    override func windowShouldClose(_ sender: NSWindow) -> Bool { finish(); return false }

    static func runUISmokeChecks() throws -> [String] {
        let original = [SFTPJumpHost(host: "first.example", username: "first"), SFTPJumpHost(host: "second.example", port: 2200, username: "second")]
        let editor = SFTPJumpHostsWindow(hosts: original)
        var submitted: [SFTPJumpHost]?
        editor.onApply = { submitted = $0 }
        editor.hosts[1].stringValue = "edited.example"
        editor.authentication[0].selectItem(at: 1); editor.authenticationChanged(editor.authentication[0])
        editor.authentication[1].selectItem(at: 2); editor.authenticationChanged(editor.authentication[1])
        guard !editor.keys[0].isEnabled, editor.keys[1].isEnabled else { throw NetworkError.io("Jump key availability must follow endpoint authentication mode") }
        editor.apply()
        guard submitted?.first?.host == original.first?.host, submitted?.first?.authenticationMode == .password, submitted?.last?.authenticationMode == .interactive, submitted?.last?.host == "edited.example", submitted?.last?.port == 2200 else {
            throw NetworkError.io("The jump host editor must preserve order and submit edited endpoint fields")
        }
        return ["SSH jump editor preserves route order, endpoint authentication modes and key availability"]
    }
}
