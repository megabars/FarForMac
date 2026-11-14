import AppKit
import FarCore

@MainActor
final class NetworkConnectionWindow: FileToolsWindowController, NSTextFieldDelegate {
    var onConnect: ((NetworkConnection, String?, Bool, Bool) -> Void)?
    var onSaveSession: ((NetworkConnection, String?, Bool) throws -> Void)?
    var canConnect: () -> Bool = { true }
    private let profiles: [NetworkConnection]
    private let sessionPath: String?
    private let preset: NetworkConnection?
    private let saved = NSPopUpButton(), kind = NSPopUpButton(), authentication = NSPopUpButton()
    private let name = NSTextField(), host = NSTextField(), port = NSTextField(), user = NSTextField(), path = NSTextField(), key = NSTextField()
    private let password = NSSecureTextField(), timeout = NSTextField()
    private let remember = NSButton(checkboxWithTitle: "Сохранить параметры подключения", target: nil, action: nil)
    private let rememberSecret = NSButton(checkboxWithTitle: "Сохранить пароль в Связке ключей", target: nil, action: nil)
    private let importSSH = NSButton(), editJumps = NSButton()
    private var jumpHosts: [SFTPJumpHost] = []
    private var jumpWindow: SFTPJumpHostsWindow?
    private var profileID = UUID()
    private var profileGroup: [String] = []
    init(profiles suppliedProfiles: [NetworkConnection]? = nil, connection: NetworkConnection? = nil, sessionPath: String? = nil) {
        var failure: Error?
        preset = connection; self.sessionPath = sessionPath
        if connection != nil || sessionPath != nil { profiles = [] }
        else if let suppliedProfiles { profiles = suppliedProfiles }
        else { do { profiles = try NetworkProfileStore.load() } catch { profiles = []; failure = error } }
        let title = sessionPath == nil ? "Сетевое подключение" :
            connection == nil ? "Новое подключение" : L10n.text("Редактирование подключения")
        super.init(title: title, width: 760, height: 790)
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
        for field in [host, port, user, key] { field.delegate = self }
        host.placeholderString = "server.example.org"; password.placeholderString = "Не сохраняется без отметки ниже"
        var fields: [(String, NSView)] = [("Название", name), ("Протокол", row([kind, importSSH])), ("Сервер", host), ("Порт", port), ("Пользователь", user), ("Начальная папка", path), ("Способ входа SFTP", row([authentication, editJumps])), ("Закрытый SSH-ключ", key), ("Пароль", password), ("Таймаут, секунд", timeout)]
        if sessionPath == nil && connection == nil { fields.insert(("Сохранённое", saved), at: 0) }
        let grid = NSGridView(views: fields.map { [NSTextField(labelWithString: L10n.text($0.0)), $0.1] })
        grid.rowSpacing = 10; grid.columnSpacing = 12; grid.column(at: 0).width = 165
        let note = NSTextField(wrappingLabelWithString: L10n.text("SFTP: выберите SSH-ключ / agent, пароль или интерактивный вход / MFA. Ответы на запросы сервера не сохраняются. Сохранение обычного пароля в Связке ключей включается отдельно. Для FTPS/HTTPS сертификаты проверяются системой. SMB открывайте как смонтированную папку macOS."))
        let cancel = button("Отмена", #selector(cancelConnection))
        let login = button("Подключиться", #selector(connect))
        if sessionPath != nil {
            let save = button(L10n.text("Сохранить"), #selector(saveSession))
            save.keyEquivalent = "\r"
            content([grid, rememberSecret, note, status, NSView(), row([cancel, NSView(), save, login])])
        } else {
            content([grid, remember, rememberSecret, note, status, NSView(), row([cancel, NSView(), login])])
        }
        status.stringValue = failure?.localizedDescription ?? "Ключ нового SSH-сервера потребуется проверить перед подключением."
        protocolChanged()
        if let connection { applyProfile(connection) }
        if let sessionPath { name.stringValue = sessionPath }
        if sessionPath != nil && connection == nil { window?.initialFirstResponder = host }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func windowWillClose(_ notification: Notification) {
        password.stringValue = ""
        super.windowWillClose(notification)
    }
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
        guard saved.indexOfSelectedItem > 0 else { profileID = UUID(); profileGroup = []; name.stringValue = ""; host.stringValue = ""; jumpHosts = []; updateJumpTitle(); return }
        applyProfile(profiles[saved.indexOfSelectedItem - 1])
    }
    private func applyProfile(_ value: NetworkConnection) {
        profileID = value.id; profileGroup = value.profileGroup
        kind.selectItem(at: NetworkProtocol.allCases.firstIndex(of: value.kind)!); protocolChanged()
        name.stringValue = value.name; host.stringValue = value.host; port.stringValue = String(value.port)
        user.stringValue = value.username; path.stringValue = value.rootPath; key.stringValue = value.privateKeyPath ?? ""
        authentication.selectItem(at: Self.authenticationIndex(value.sftpAuthenticationMode)); authenticationChanged()
        timeout.stringValue = String(value.timeoutSeconds); remember.state = .on
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
    /// Import clears the previous credential. Only an explicit edit keeps the existing profile identity.
    func applyImportedConnection(_ value: NetworkConnection) {
        profileID = sessionPath != nil ? preset?.id ?? UUID() : UUID()
        profileGroup = []; saved.selectItem(at: 0)
        kind.selectItem(at: NetworkProtocol.allCases.firstIndex(of: .sftp)!); protocolChanged()
        let parent = sessionPath.map { $0.components(separatedBy: "/").dropLast().joined(separator: "/") } ?? ""
        name.stringValue = parent.isEmpty ? value.name : parent + "/" + value.name
        host.stringValue = value.host; port.stringValue = String(value.port)
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
        let savedSession = NetworkConnectionWindow(sessionPath: "Work/")
        savedSession.host.stringValue = "saved.example"
        savedSession.authentication.selectItem(at: 1)
        savedSession.authenticationChanged()
        var savedProfile: NetworkConnection?
        var openedConnection = false
        savedSession.onSaveSession = { profile, _, _ in savedProfile = profile }
        savedSession.onConnect = { _, _, _, _ in openedConnection = true }
        savedSession.saveSession()
        guard savedProfile?.name == "saved.example", savedProfile?.profileGroup == ["Work"],
              savedProfile?.sftpAuthenticationMode == .password, !openedConnection else {
            throw NetworkError.io("A new session must save into its current group without logging in or requiring a stored password")
        }
        let edited = NetworkConnectionWindow(sessionPath: "Test session")
        defer { edited.close() }
        edited.host.stringValue = "saved.example"
        edited.authentication.selectItem(at: 1)
        edited.authenticationChanged()
        var submittedSecret: String?, rememberSubmittedSecret = false
        edited.showWindow(nil)
        guard let editWindow = edited.window, editWindow.makeFirstResponder(edited.password),
              let fieldEditor = edited.password.currentEditor() as? NSTextView else {
            throw NetworkError.io("The password field must accept focus in the session editor")
        }
        fieldEditor.insertText("fixture-pasted-password", replacementRange: NSRange(location: 0, length: 0))
        edited.rememberSecret.state = .on
        let credentialError = NetworkError.io("Fixture Keychain write failed")
        edited.onSaveSession = { _, _, _ in throw credentialError }
        edited.connect()
        guard editWindow.isVisible, edited.status.stringValue == credentialError.localizedDescription,
              edited.password.stringValue == "fixture-pasted-password" else {
            throw NetworkError.io("A Keychain failure must keep the session editor and password available for retry")
        }
        edited.onSaveSession = { _, secret, remember in
            submittedSecret = secret; rememberSubmittedSecret = remember
        }
        var connectedSecret: String?
        edited.onConnect = { _, secret, _, _ in connectedSecret = secret }
        edited.canConnect = { false }
        edited.connect()
        guard editWindow.isVisible, submittedSecret == nil, connectedSecret == nil else {
            throw NetworkError.io("A busy file manager must leave the connection editor open without saving or connecting")
        }
        edited.canConnect = { true }
        guard NSApp.sendAction(#selector(connect), to: edited, from: nil),
              submittedSecret == "fixture-pasted-password", rememberSubmittedSecret,
              connectedSecret == submittedSecret else {
            throw NetworkError.io("Connect must save and submit the password pasted into the focused field")
        }
        return ["SSH import clears saved credentials and creates a fresh editable profile", "SFTP form submits jump hosts with target password authentication", "Changing the SSH route clears the target secret", "SSH configuration controls are disabled for other protocols"] + (try SFTPJumpHostsWindow.runUISmokeChecks()) + (try SSHAuthenticationWindow.runUISmokeChecks()) + ["Interactive SFTP allows key plus MFA without a static or saved secret", "A saved session can be created inside a group without logging in or storing its password", "Session editor keeps the pasted password after storage or busy errors and submits it on retry"]
    }
    static func confirmCleartextConnection(_ type: NetworkProtocol) -> Bool {
        guard type.isCleartext else { return true }
        let alert = NSAlert(); alert.messageText = "Соединение без шифрования"
        alert.informativeText = "\(type.title) передаёт данные и пароль открытым текстом. Для защищённого подключения выберите FTPS или WebDAV (HTTPS). Продолжить с выбранным протоколом?"
        alert.addButton(withTitle: "Продолжить"); alert.addButton(withTitle: "Отмена")
        return alert.runModal() == .alertFirstButtonReturn
    }
    @objc private func connect() { submit(connect: true) }
    @objc private func saveSession() { submit(connect: false) }
    private func submit(connect shouldConnect: Bool) {
        do {
            guard window?.makeFirstResponder(nil) != false else {
                throw NetworkError.invalidConnection(L10n.text("Проверьте введённые параметры подключения."))
            }
            if shouldConnect, !canConnect() {
                throw NetworkError.io(L10n.text("Дождитесь завершения текущей файловой операции."))
            }
            let type = NetworkProtocol.allCases[max(0, kind.indexOfSelectedItem)]
            guard let number = Int(port.stringValue), let seconds = Double(timeout.stringValue) else { throw NetworkError.invalidConnection("Порт и таймаут должны быть числами.") }
            let save = remember.state == .on
            let saveSecret = rememberSecret.isEnabled && rememberSecret.state == .on
            let saveSession = !shouldConnect || preset != nil || saveSecret
            var connection = NetworkConnection(id: profileID, name: name.stringValue, kind: type,
                host: host.stringValue.trimmingCharacters(in: .whitespaces), port: number, username: user.stringValue,
                rootPath: path.stringValue, privateKeyPath: key.stringValue.isEmpty ? nil : (key.stringValue as NSString).expandingTildeInPath, timeoutSeconds: seconds,
                sftpAuthenticationMode: Self.authenticationMode(authentication.indexOfSelectedItem),
                sftpJumpHosts: type == .sftp ? jumpHosts : [], profileGroup: profileGroup)
            if let sessionPath {
                if let preset, name.stringValue == sessionPath {
                    connection.name = preset.name
                    connection.profileGroup = preset.profileGroup
                } else if saveSession {
                    let value = name.stringValue == sessionPath && sessionPath.hasSuffix("/")
                        ? sessionPath + connection.host : name.stringValue
                    connection = try SavedNetworkProfiles.assigningPath(value.isEmpty ? connection.host : value, to: connection)
                }
            }
            try connection.validate()
            let secret = password.isEnabled ? password.stringValue : nil
            if shouldConnect || saveSecret, type == .sftp, connection.sftpAuthenticationMode == .password, secret?.isEmpty ?? true {
                throw NetworkError.invalidConnection(L10n.text("Введите пароль для входа SFTP."))
            }
            if sessionPath != nil {
                if saveSession { try onSaveSession?(connection, secret, saveSecret) }
                password.stringValue = ""; close()
                if shouldConnect { onConnect?(connection, secret, false, false) }
                return
            }
            if shouldConnect && !Self.confirmCleartextConnection(type) { return }
            guard !saveSecret || save else { status.stringValue = "Для пароля в Связке ключей сохраните и параметры подключения."; return }
            password.stringValue = ""; close()
            onConnect?(connection, secret, save, saveSecret)
        } catch {
            status.textColor = .systemRed
            status.stringValue = error.localizedDescription
        }
    }
}
