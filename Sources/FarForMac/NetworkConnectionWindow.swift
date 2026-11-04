import AppKit
import FarCore

@MainActor
final class NetworkConnectionWindow: FileToolsWindowController, NSTextFieldDelegate {
    var onConnect: ((NetworkConnection, String?, Bool, Bool) -> Void)?
    private let profiles: [NetworkConnection]
    private let saved = NSPopUpButton(), kind = NSPopUpButton(), authentication = NSPopUpButton()
    private let name = NSTextField(), host = NSTextField(), port = NSTextField(), user = NSTextField(), path = NSTextField(), key = NSTextField()
    private let password = NSSecureTextField(), timeout = NSTextField()
    private let remember = NSButton(checkboxWithTitle: "Сохранить параметры подключения", target: nil, action: nil)
    private let rememberSecret = NSButton(checkboxWithTitle: "Сохранить пароль в Связке ключей", target: nil, action: nil)
    private let importSSH = NSButton(), editJumps = NSButton()
    private var jumpHosts: [SFTPJumpHost] = []
    private var jumpWindow: SFTPJumpHostsWindow?
    private var profileID = UUID()
    init(profiles suppliedProfiles: [NetworkConnection]? = nil) {
        var failure: Error?
        if let suppliedProfiles { profiles = suppliedProfiles }
        else { do { profiles = try NetworkProfileStore.load() } catch { profiles = []; failure = error } }
        super.init(title: "Сетевое подключение", width: 760, height: 790)
        saved.addItem(withTitle: "Новое подключение")
        profiles.forEach { saved.addItem(withTitle: $0.displayName) }
        saved.target = self; saved.action = #selector(loadProfile)
        kind.addItems(withTitles: NetworkProtocol.allCases.map(\.title)); kind.target = self; kind.action = #selector(protocolChanged)
        authentication.addItems(withTitles: [L10n.text("SSH-ключ / agent"), L10n.text("Пароль"), L10n.text("Интерактивный / MFA")]); authentication.target = self; authentication.action = #selector(authenticationChanged)
        importSSH.title = L10n.text("Импорт SSH config…"); importSSH.target = self; importSSH.action = #selector(importSSHConfiguration)
        editJumps.target = self; editJumps.action = #selector(editJumpHosts)
        for control in [importSSH, editJumps] { control.bezelStyle = .rounded }
        updateJumpTitle()
        port.stringValue = "22"; path.stringValue = "/"; timeout.stringValue = "30"
        user.stringValue = NSUserName()
        key.placeholderString = "Путь к ключу; пусто — SSH agent / стандартные ключи"
        for field in [host, port, user] { field.delegate = self }
        host.placeholderString = "server.example.org"; password.placeholderString = "Не сохраняется без отметки ниже"
        let fields: [(String, NSView)] = [("Сохранённое", saved), ("Название", name), ("Протокол", row([kind, importSSH])), ("Сервер", host), ("Порт", port), ("Пользователь", user), ("Начальная папка", path), ("Способ входа SFTP", row([authentication, editJumps])), ("Закрытый SSH-ключ", key), ("Пароль", password), ("Таймаут, секунд", timeout)]
        let grid = NSGridView(views: fields.map { [NSTextField(labelWithString: L10n.text($0.0)), $0.1] })
        grid.rowSpacing = 10; grid.columnSpacing = 12; grid.column(at: 0).width = 165
        let note = NSTextField(wrappingLabelWithString: L10n.text("SFTP: выберите SSH-ключ / agent, пароль или интерактивный вход / MFA. Ответы на запросы сервера не сохраняются. Сохранение обычного пароля в Связке ключей включается отдельно. Для FTPS/HTTPS сертификаты проверяются системой. SMB открывайте как смонтированную папку macOS."))
        content([grid, remember, rememberSecret, note, status, NSView(), row([button("Отмена", #selector(cancelConnection)), NSView(), button("Подключиться", #selector(connect))])])
        status.stringValue = failure?.localizedDescription ?? "Ключ нового SSH-сервера потребуется проверить перед подключением."
        protocolChanged()
    }
    required init?(coder: NSCoder) { fatalError() }
    func controlTextDidChange(_ obj: Notification) { password.stringValue = ""; rememberSecret.state = .off }
    @objc private func protocolChanged() {
        password.stringValue = ""; rememberSecret.state = .off
        let value = NetworkProtocol.allCases[max(0, kind.indexOfSelectedItem)]
        port.stringValue = String(value.defaultPort)
        authentication.isEnabled = value == .sftp
        importSSH.isEnabled = value == .sftp; editJumps.isEnabled = value == .sftp
        authenticationChanged()
    }
    private static func authenticationIndex(_ mode: SFTPAuthenticationMode) -> Int {
        switch mode { case .keyAgent: return 0; case .password: return 1; case .interactive: return 2 }
    }
    private static func authenticationMode(_ index: Int) -> SFTPAuthenticationMode {
        switch index { case 1: return .password; case 2: return .interactive; default: return .keyAgent }
    }
    @objc private func authenticationChanged() {
        password.stringValue = ""; rememberSecret.state = .off
        let isSFTP = NetworkProtocol.allCases[max(0, kind.indexOfSelectedItem)] == .sftp
        let usesPassword = !isSFTP || authentication.indexOfSelectedItem == 1
        key.isEnabled = isSFTP && !usesPassword
        password.isEnabled = usesPassword; rememberSecret.isEnabled = usesPassword
    }
    @objc private func loadProfile() {
        password.stringValue = ""; rememberSecret.state = .off
        guard saved.indexOfSelectedItem > 0 else { profileID = UUID(); name.stringValue = ""; host.stringValue = ""; jumpHosts = []; updateJumpTitle(); return }
        let value = profiles[saved.indexOfSelectedItem - 1]; profileID = value.id
        kind.selectItem(at: NetworkProtocol.allCases.firstIndex(of: value.kind)!); protocolChanged()
        name.stringValue = value.name; host.stringValue = value.host; port.stringValue = String(value.port)
        user.stringValue = value.username; path.stringValue = value.rootPath; key.stringValue = value.privateKeyPath ?? ""
        authentication.selectItem(at: Self.authenticationIndex(value.sftpAuthenticationMode)); authenticationChanged()
        timeout.stringValue = String(Int(value.timeoutSeconds)); remember.state = .on
        jumpHosts = value.sftpJumpHosts; updateJumpTitle()
        if password.isEnabled {
            do {
                if let storedPassword = try NetworkCredentials.password(for: value.id) {
                    password.stringValue = storedPassword; rememberSecret.state = .on
                }
            }
            catch { status.stringValue = error.localizedDescription }
        }
    }
    private func updateJumpTitle() {
        editJumps.title = L10n.text("Промежуточные SSH-серверы…") + " (\(jumpHosts.count)/4)"
    }
    @objc private func importSSHConfiguration() {
        let chooser = NSOpenPanel(); chooser.canChooseDirectories = false; chooser.allowsMultipleSelection = false
        chooser.title = L10n.text("Выберите SSH config")
        chooser.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        guard chooser.runModal() == .OK, let url = chooser.url else { return }
        let alert = NSAlert(); alert.messageText = L10n.text("Имя Host из SSH config")
        alert.informativeText = L10n.text("Будут импортированы только параметры подключения. Проверьте сервер и цепочку переходов перед входом.")
        let alias = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        alias.placeholderString = "Host alias"; alert.accessoryView = alias; alert.window.initialFirstResponder = alias
        alert.addButton(withTitle: L10n.text("Импортировать")); alert.addButton(withTitle: L10n.text("Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { applyImportedConnection(try SSHConfiguration.importConnection(alias: alias.stringValue, from: url)) }
        catch { status.stringValue = error.localizedDescription }
    }
    /// Import never reuses a saved profile identity or loads that profile's Keychain secret.
    func applyImportedConnection(_ value: NetworkConnection) {
        profileID = UUID(); saved.selectItem(at: 0)
        kind.selectItem(at: NetworkProtocol.allCases.firstIndex(of: .sftp)!); protocolChanged()
        name.stringValue = value.name; host.stringValue = value.host; port.stringValue = String(value.port)
        user.stringValue = value.username; path.stringValue = value.rootPath; key.stringValue = value.privateKeyPath ?? ""
        timeout.stringValue = String(Int(value.timeoutSeconds))
        authentication.selectItem(at: Self.authenticationIndex(value.sftpAuthenticationMode)); authenticationChanged()
        jumpHosts = value.sftpJumpHosts; updateJumpTitle()
        remember.state = .off
        status.stringValue = L10n.text("Параметры импортированы. Проверьте сервер и промежуточные SSH-серверы перед подключением.")
    }
    @objc private func editJumpHosts() {
        guard let parent = window else { return }
        let editor = SFTPJumpHostsWindow(hosts: jumpHosts); jumpWindow = editor
        editor.onApply = { [weak self] hosts in self?.applyJumpHosts(hosts) }
        editor.onClose = { [weak self] in self?.jumpWindow = nil }
        if let sheet = editor.window { parent.beginSheet(sheet) }
    }
    private func applyJumpHosts(_ hosts: [SFTPJumpHost]) {
        if jumpHosts != hosts { password.stringValue = ""; rememberSecret.state = .off }
        jumpHosts = hosts; updateJumpTitle()
    }
    @objc private func cancelConnection() { password.stringValue = ""; close() }
    /// Exercises the real form without reading profiles, accessing Keychain, or connecting.
    static func runUISmokeChecks() throws -> [String] {
        let form = NetworkConnectionWindow(profiles: [])
        let imported = NetworkConnection(name: "fixture", kind: .sftp, host: "target.example", username: "target-user",
            sftpAuthenticationMode: .password, sftpJumpHosts: [SFTPJumpHost(host: "jump.example", username: "jump-user")])
        form.password.stringValue = "previous-secret"; form.rememberSecret.state = .on
        form.applyImportedConnection(imported)
        guard form.profileID != imported.id, form.password.stringValue.isEmpty, form.rememberSecret.state == .off,
              form.saved.indexOfSelectedItem == 0, form.host.stringValue == imported.host,
              form.jumpHosts == imported.sftpJumpHosts else {
            throw NetworkError.io("SSH import must populate editable settings with a fresh identity and no saved secret")
        }
        form.password.stringValue = "fixture-secret"
        var submitted: NetworkConnection?
        form.onConnect = { connection, _, _, _ in submitted = connection }
        form.connect()
        guard submitted?.sftpJumpHosts == imported.sftpJumpHosts, submitted?.sftpAuthenticationMode == .password,
              submitted?.host == imported.host else { throw NetworkError.io("The connection form must preserve imported jump hosts and target authentication") }
        form.password.stringValue = "previous-route-secret"; form.rememberSecret.state = .on
        form.applyJumpHosts([])
        guard form.password.stringValue.isEmpty, form.rememberSecret.state == .off else { throw NetworkError.io("Editing the SSH route must clear the target secret and Keychain save selection") }
        let other = NetworkConnectionWindow(profiles: [])
        other.kind.selectItem(at: NetworkProtocol.allCases.firstIndex(of: .ftp)!); other.protocolChanged()
        guard !other.importSSH.isEnabled, !other.editJumps.isEnabled else { throw NetworkError.io("SSH import and jump controls must be SFTP-only") }
        other.close()
        let interactive = NetworkConnectionWindow(profiles: [])
        interactive.authentication.selectItem(at: 2); interactive.password.stringValue = "discard-fixture"
        interactive.rememberSecret.state = .on; interactive.authenticationChanged()
        interactive.host.stringValue = "mfa.example"; interactive.key.stringValue = "/fixture/key"
        var mfaSubmission: NetworkConnection?, mfaSecret: String?, mfaSaveSecret = true
        interactive.onConnect = { value, secret, _, saveSecret in mfaSubmission = value; mfaSecret = secret; mfaSaveSecret = saveSecret }
        guard interactive.key.isEnabled, !interactive.password.isEnabled, !interactive.rememberSecret.isEnabled,
              interactive.password.stringValue.isEmpty, interactive.rememberSecret.state == .off else {
            throw NetworkError.io("Interactive SFTP must allow a key and disable static or stored answers")
        }
        interactive.connect()
        guard mfaSubmission?.sftpAuthenticationMode == .interactive, mfaSubmission?.privateKeyPath == "/fixture/key",
              mfaSecret == nil, !mfaSaveSecret else { throw NetworkError.io("Interactive SFTP must submit without a saved answer") }
        return ["SSH import clears saved credentials and creates a fresh editable profile", "SFTP form submits jump hosts with target password authentication", "Changing the SSH route clears the target secret", "SSH configuration controls are disabled for other protocols"] + (try SFTPJumpHostsWindow.runUISmokeChecks()) + (try SSHAuthenticationWindow.runUISmokeChecks()) + ["Interactive SFTP allows key plus MFA without a static or saved secret"]
    }
    @objc private func connect() {
        do {
            let type = NetworkProtocol.allCases[max(0, kind.indexOfSelectedItem)]
            guard let number = Int(port.stringValue), let seconds = Double(timeout.stringValue) else { throw NetworkError.invalidConnection("Порт и таймаут должны быть числами.") }
            let connection = NetworkConnection(id: profileID, name: name.stringValue, kind: type,
                host: host.stringValue.trimmingCharacters(in: .whitespaces), port: number, username: user.stringValue,
                rootPath: path.stringValue, privateKeyPath: key.stringValue.isEmpty ? nil : (key.stringValue as NSString).expandingTildeInPath, timeoutSeconds: seconds,
                sftpAuthenticationMode: Self.authenticationMode(authentication.indexOfSelectedItem),
                sftpJumpHosts: type == .sftp ? jumpHosts : [])
            try connection.validate()
            if type.isCleartext {
                let alert = NSAlert(); alert.messageText = "Соединение без шифрования"
                alert.informativeText = "\(type.title) передаёт данные и пароль открытым текстом. Для защищённого подключения выберите FTPS или WebDAV (HTTPS). Продолжить с выбранным протоколом?"
                alert.addButton(withTitle: "Продолжить"); alert.addButton(withTitle: "Отмена")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            let secret = password.isEnabled ? password.stringValue : nil
            if type == .sftp && connection.sftpAuthenticationMode == .password && (secret?.isEmpty ?? true) {
                throw NetworkError.invalidConnection(L10n.text("Введите пароль для входа SFTP."))
            }
            let save = remember.state == .on, saveSecret = rememberSecret.isEnabled && rememberSecret.state == .on
            guard !saveSecret || save else { status.stringValue = "Для пароля в Связке ключей сохраните и параметры подключения."; return }
            password.stringValue = ""; close()
            onConnect?(connection, secret, save, saveSecret)
        } catch { status.stringValue = error.localizedDescription }
    }
}
