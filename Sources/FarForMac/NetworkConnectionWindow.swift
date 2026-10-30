import AppKit
import FarCore

@MainActor
final class NetworkConnectionWindow: FileToolsWindowController, NSTextFieldDelegate {
    var onConnect: ((NetworkConnection, String?, Bool, Bool) -> Void)?
    private let profiles: [NetworkConnection]
    private let saved = NSPopUpButton(), kind = NSPopUpButton()
    private let name = NSTextField(), host = NSTextField(), port = NSTextField(), user = NSTextField(), path = NSTextField(), key = NSTextField()
    private let password = NSSecureTextField(), timeout = NSTextField()
    private let remember = NSButton(checkboxWithTitle: "Сохранить параметры подключения", target: nil, action: nil)
    private let rememberSecret = NSButton(checkboxWithTitle: "Сохранить пароль в Связке ключей", target: nil, action: nil)
    private var profileID = UUID()
    init() {
        var failure: Error?
        do { profiles = try NetworkProfileStore.load() } catch { profiles = []; failure = error }
        super.init(title: "Сетевое подключение", width: 660, height: 680)
        saved.addItem(withTitle: "Новое подключение")
        profiles.forEach { saved.addItem(withTitle: $0.displayName) }
        saved.target = self; saved.action = #selector(loadProfile)
        kind.addItems(withTitles: NetworkProtocol.allCases.map(\.title)); kind.target = self; kind.action = #selector(protocolChanged)
        port.stringValue = "22"; path.stringValue = "/"; timeout.stringValue = "30"
        user.stringValue = NSUserName()
        key.placeholderString = "Путь к ключу; пусто — SSH agent / стандартные ключи"
        for field in [host, port, user] { field.delegate = self }
        host.placeholderString = "server.example.org"; password.placeholderString = "Не сохраняется без отметки ниже"
        let fields: [(String, NSView)] = [("Сохранённое", saved), ("Название", name), ("Протокол", kind), ("Сервер", host), ("Порт", port), ("Пользователь", user), ("Начальная папка", path), ("Закрытый SSH-ключ", key), ("Пароль", password), ("Таймаут, секунд", timeout)]
        let grid = NSGridView(views: fields.map { [NSTextField(labelWithString: $0.0), $0.1] })
        grid.rowSpacing = 10; grid.columnSpacing = 12; grid.column(at: 0).width = 165
        let note = NSTextField(wrappingLabelWithString: "SFTP: ключи/SSH agent, пароль ключа — через macOS Keychain. Пароль входа SSH пока не поддерживается. Для FTPS/HTTPS сертификаты проверяются системой. SMB открывайте как смонтированную папку macOS.")
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
        key.isEnabled = value == .sftp; password.isEnabled = value != .sftp; rememberSecret.isEnabled = value != .sftp
        if value == .sftp { password.stringValue = ""; rememberSecret.state = .off }
    }
    @objc private func loadProfile() {
        password.stringValue = ""; rememberSecret.state = .off
        guard saved.indexOfSelectedItem > 0 else { profileID = UUID(); name.stringValue = ""; host.stringValue = ""; return }
        let value = profiles[saved.indexOfSelectedItem - 1]; profileID = value.id
        kind.selectItem(at: NetworkProtocol.allCases.firstIndex(of: value.kind)!); protocolChanged()
        name.stringValue = value.name; host.stringValue = value.host; port.stringValue = String(value.port)
        user.stringValue = value.username; path.stringValue = value.rootPath; key.stringValue = value.privateKeyPath ?? ""
        timeout.stringValue = String(Int(value.timeoutSeconds)); remember.state = .on
        if value.kind != .sftp {
            do { password.stringValue = try NetworkCredentials.password(for: value.id) ?? "" }
            catch { status.stringValue = error.localizedDescription }
        }
    }
    @objc private func cancelConnection() { password.stringValue = ""; close() }
    @objc private func connect() {
        do {
            let type = NetworkProtocol.allCases[max(0, kind.indexOfSelectedItem)]
            guard let number = Int(port.stringValue), let seconds = Double(timeout.stringValue) else { throw NetworkError.invalidConnection("Порт и таймаут должны быть числами.") }
            let connection = NetworkConnection(id: profileID, name: name.stringValue, kind: type,
                host: host.stringValue.trimmingCharacters(in: .whitespaces), port: number, username: user.stringValue,
                rootPath: path.stringValue, privateKeyPath: key.stringValue.isEmpty ? nil : (key.stringValue as NSString).expandingTildeInPath, timeoutSeconds: seconds)
            try connection.validate()
            if type.isCleartext {
                let alert = NSAlert(); alert.messageText = "Соединение без шифрования"
                alert.informativeText = "\(type.title) передаёт данные и пароль открытым текстом. Для защищённого подключения выберите FTPS или WebDAV (HTTPS). Продолжить с выбранным протоколом?"
                alert.addButton(withTitle: "Продолжить"); alert.addButton(withTitle: "Отмена")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            let secret = type == .sftp ? nil : password.stringValue
            let save = remember.state == .on, saveSecret = rememberSecret.state == .on
            guard !saveSecret || save else { status.stringValue = "Для пароля в Связке ключей сохраните и параметры подключения."; return }
            password.stringValue = ""; close()
            onConnect?(connection, secret, save, saveSecret)
        } catch { status.stringValue = error.localizedDescription }
    }
}
