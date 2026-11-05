import AppKit
import FarCore

@MainActor final class LocalNetworkPanelView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onFocus: (() -> Void)?
    var onClose: (() -> Void)?
    var onSwitchPanel: (() -> Void)?
    var onChange: (() -> Void)?
    var onOpenMounted: ((URL) -> Void)?

    private enum Row: Hashable {
        case up, server(LocalSMBAdvertisement), share(LocalSMBShare)
    }

    private struct ServerLevel {
        let address: LocalSMBServer
        let advertisement: LocalSMBAdvertisement?
        let account: LocalSMBAccount?
        let shares: [LocalSMBShare]
    }

    private let table = FileTable()
    private let status = label("", size: 11, color: Palette.muted)
    private let cancelButton = NSButton(title: "Отменить", target: nil, action: nil)
    private let discovery = LocalSMBBonjour()
    private let resolver = LocalSMBResolver()
    private let listing = LocalSMBShareListing()
    private let mount = LocalSMBMountRequest()
    private var started = false
    private var active = false
    private var operation: UUID?
    private var disconnecting = false
    private var discoveryProblem = ""
    private var discovered: [LocalSMBAdvertisement] = []
    private var server: ServerLevel?
    private var retryServer: LocalSMBServer?
    private var rows: [Row] = [.up]
    private var mounted: [LocalSMBShare: [LocalSMBMount]] = [:]

    var caption: String { server.map { "smb://\($0.address.displayAddress)" } ?? "Локальная сеть" }
    private var cursor: Row? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }

    init() {
        super.init(frame: .zero)
        table.backgroundColor = Palette.panel
        table.rowHeight = 29
        table.intercellSpacing = .zero
        table.allowsEmptySelection = false
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClick)
        table.setAccessibilityLabel("Панель локальной сети")
        table.onFocus = { [weak self] in self?.onFocus?() }
        table.onKey = { [weak self] event in self?.key(event) ?? false }

        let column = NSTableColumn(identifier: .init("name"))
        column.title = "Сервер / общая папка"
        column.minWidth = 100
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        let addressButton = NSButton(title: "Сервер…", target: self, action: #selector(enterAddress))
        let refreshButton = NSButton(title: "Обновить", target: self, action: #selector(refreshButtonPressed))
        cancelButton.target = self
        cancelButton.action = #selector(cancelButtonPressed)
        cancelButton.isHidden = true
        let buttons = NSStackView(views: [addressButton, refreshButton, cancelButton])
        buttons.orientation = .horizontal
        status.lineBreakMode = .byTruncatingTail
        status.toolTip = nil
        status.setAccessibilityLabel("Состояние локальной сети")
        let body = vertical([scroll, inset(status, x: 10, y: 4), inset(buttons, x: 10, y: 6)])
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: leadingAnchor), body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.topAnchor.constraint(equalTo: topAnchor), body.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func start() {
        guard !started else { return }
        started = true
        browse()
    }

    func stop() {
        started = false
        cancelRequest()
        discovery.stop()
        discovered = []
        discoveryProblem = ""
        server = nil
        retryServer = nil
        mounted = [:]
    }

    func focus() { window?.makeFirstResponder(table) }

    func setActive(_ value: Bool) {
        active = value
        table.enumerateAvailableRowViews { view, _ in
            (view as? FileRow)?.active = value
            view.needsDisplay = true
        }
    }

    func refresh() {
        guard started, !disconnecting else { return }
        cancelRequest()
        if let server {
            loadShares(server.address, advertisement: server.advertisement, account: server.account)
        } else {
            browse(preferred: cursor)
        }
    }

    func goUp() {
        guard !disconnecting else { return }
        cancelRequest()
        if let server {
            self.server = nil
            retryServer = nil
            mounted = [:]
            browse(preferred: server.advertisement.map(Row.server))
        } else {
            onClose?()
        }
    }

    /// Direct entry mirrors net:server_name for devices which do not advertise SMB.
    @discardableResult func openServer(_ address: String, explicit: Bool = false) -> Bool {
        guard started, operation == nil else { return false }
        retryServer = nil
        do {
            let server = try LocalSMBServer(address: address)
            let account: LocalSMBAccount?
            if explicit {
                guard let value = requestAccount(server: server) else { return false }
                account = value
            } else {
                account = nil
            }
            retryServer = server
            loadShares(server, advertisement: nil, account: account)
            return true
        } catch {
            showStatus(error.localizedDescription)
            return false
        }
    }

    func openSelection() {
        guard started, operation == nil, let cursor else { return }
        switch cursor {
        case .up: goUp()
        case .server(let advertisement): resolve(advertisement, explicit: false)
        case .share(let share): openShare(share, account: server?.account, navigate: true)
        }
    }

    @discardableResult func performFunction(_ number: Int) -> Bool {
        switch number {
        case 3, 7: return true
        case 4, 5, 6, 8:
            guard started, operation == nil else { return true }
        default: return false
        }
        switch number {
        case 4: explicitLogin()
        case 5:
            if case .share(let share) = cursor { openShare(share, account: server?.account, navigate: false) }
        case 6: showStatus("Выбор буквы диска недоступен в macOS. F5 подключает том SMB.")
        case 8: disconnectSelection()
        default: break
        }
        return true
    }

    private func browse(preferred: Row? = nil) {
        discovered = []
        discoveryProblem = ""
        showStatus("Поиск SMB-серверов через Bonjour…")
        reload(preferred: preferred)
        var pendingSelection = preferred
        discovery.start(onResults: { [weak self] advertisements in
            guard let self, self.started, self.server == nil else { return }
            let firstResult = self.discovered.isEmpty ? advertisements.first.map(Row.server) : nil
            self.discovered = advertisements
            self.reload(preferred: pendingSelection.flatMap { selection in
                advertisements.contains(where: { Row.server($0) == selection }) ? selection : nil
            } ?? firstResult)
            if let pending = pendingSelection, self.rows.contains(pending) { pendingSelection = nil }
            if self.operation == nil { self.showBrowseStatus() }
        }, onProblem: { [weak self] problem in
            guard let self, self.started, self.server == nil else { return }
            self.discoveryProblem = problem
            if self.operation == nil { self.showBrowseStatus() }
        })
    }

    private func showBrowseStatus() {
        if !discoveryProblem.isEmpty {
            showStatus(discoveryProblem)
        } else if discovered.isEmpty {
            showStatus("Bonjour пока не обнаружил SMB-серверы. Можно указать адрес.")
        } else {
            showStatus("Серверов: \(discovered.count) · Enter открыть · F4 вход · Ctrl+R обновить")
        }
    }

    private func showSharesStatus() {
        guard let server else { return }
        if server.shares.isEmpty {
            showStatus("Нет доступных файловых ресурсов SMB. F4 — вход, Ctrl+R — обновить.")
        } else {
            showStatus("Общих папок: \(server.shares.count) · Enter открыть · F4 вход · F5 подключить · F8 отключить")
        }
    }

    private func resolve(_ advertisement: LocalSMBAdvertisement, explicit: Bool) {
        retryServer = nil
        let token = begin("Определяется адрес SMB-сервера…")
        resolver.resolve(advertisement) { [weak self] result in
            guard let self, self.end(token) else { return }
            switch result {
            case .success(let server):
                if explicit {
                    self.showBrowseStatus()
                    guard let account = self.requestAccount(server: server) else { return }
                    self.loadShares(server, advertisement: advertisement, account: account)
                } else {
                    self.loadShares(server, advertisement: advertisement, account: nil)
                }
            case .failure(let error):
                self.showStatus(error.localizedDescription)
            }
        }
    }

    private func loadShares(_ address: LocalSMBServer, advertisement: LocalSMBAdvertisement?, account: LocalSMBAccount?) {
        let token = begin("Чтение общих папок SMB…")
        listing.start(server: address, account: account) { [weak self] result in
            guard let self, self.end(token) else { return }
            switch result {
            case .success(let shares):
                self.discovery.stop()
                self.server = ServerLevel(address: address, advertisement: advertisement, account: account, shares: shares)
                self.retryServer = nil
                self.reloadMounts()
                self.reload()
                self.showSharesStatus()
                self.onChange?()
            case .failure(let error):
                if self.server == nil, self.retryServer == address { self.reload(preferred: .up) }
                self.showStatus(error.localizedDescription)
            }
        }
    }

    private func openShare(_ share: LocalSMBShare, account: LocalSMBAccount?, navigate: Bool) {
        guard let server else { return }
        let token = begin("Подключение общей папки SMB…")
        mount.start(server: server.address, share: share, account: account) { [weak self] result in
            guard let self, self.end(token) else { return }
            switch result {
            case .success(let url):
                self.reloadMounts()
                self.reload()
                if navigate { self.onOpenMounted?(url) }
                else { self.showStatus("Том подключён · \(url.path)") }
            case .failure(let error):
                self.showStatus(error is CancellationError ? "Подключение отменено." : error.localizedDescription)
            }
        }
    }

    private func explicitLogin() {
        if server == nil, cursor == .up, let retryServer {
            if let account = requestAccount(server: retryServer) {
                loadShares(retryServer, advertisement: nil, account: account)
            }
            return
        }
        switch cursor {
        case .server(let advertisement):
            resolve(advertisement, explicit: true)
        case .share(let share):
            if let server, let account = requestAccount(server: server.address, share: share) {
                openShare(share, account: account, navigate: true)
            }
        case .up, nil:
            if let server, let account = requestAccount(server: server.address) {
                loadShares(server.address, advertisement: server.advertisement, account: account)
            }
        }
    }

    private func requestAccount(server: LocalSMBServer, share: LocalSMBShare? = nil) -> LocalSMBAccount? {
        let alert = NSAlert()
        alert.messageText = "Учётные данные SMB"
        let destination = server.displayAddress + (share.map { "/" + $0.name } ?? "")
        alert.informativeText = "smb://\(destination)\nДля домена используйте ДОМЕН\\пользователь."
        let user = NSTextField()
        user.placeholderString = "Имя пользователя"
        user.setAccessibilityLabel("Имя пользователя SMB")
        let password = NSSecureTextField()
        password.placeholderString = "Пароль"
        password.setAccessibilityLabel("Пароль SMB")
        let fields = NSStackView(views: [user, password])
        fields.orientation = .vertical
        fields.alignment = .leading
        user.widthAnchor.constraint(equalToConstant: 300).isActive = true
        password.widthAnchor.constraint(equalTo: user.widthAnchor).isActive = true
        alert.accessoryView = fields
        alert.addButton(withTitle: "Войти")
        alert.addButton(withTitle: "Отмена")
        alert.window.initialFirstResponder = user
        let response = alert.runModal()
        defer { password.stringValue = ""; focus() }
        guard response == .alertFirstButtonReturn, started else { return nil }
        do {
            return try LocalSMBAccount(user: user.stringValue, password: password.stringValue)
        } catch {
            showStatus(error.localizedDescription)
            return nil
        }
    }

    private func reloadMounts() {
        guard let server else { return }
        mounted = LocalSMBMount.matching(server: server.address, shares: server.shares)
    }

    private func disconnectSelection() {
        guard case .share(let share) = cursor, server != nil else { return }
        reloadMounts()
        guard let volumes = mounted[share], !volumes.isEmpty else {
            reload()
            showStatus("Для выбранной общей папки нет подключённого тома SMB.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Отключить том SMB?"
        alert.informativeText = share.name
        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        if volumes.count == 1 {
            alert.informativeText = volumes[0].url.path
        } else {
            picker.addItems(withTitles: volumes.map { $0.url.path })
            alert.accessoryView = picker
        }
        alert.addButton(withTitle: "Отключить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn, started else { focus(); return }
        let selected = volumes[max(0, picker.indexOfSelectedItem)]
        disconnecting = true
        let token = begin("Отключение тома SMB…", cancellable: false)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try selected.disconnect() } }.value
            guard let self, self.end(token) else { return }
            self.reloadMounts()
            self.reload()
            switch result {
            case .success: self.showStatus("Том SMB отключён.")
            case .failure(let error): self.showStatus(error.localizedDescription)
            }
        }
        focus()
    }

    @objc private func enterAddress() {
        guard started, operation == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Открыть SMB-сервер"
        alert.informativeText = "Введите имя или IP-адрес сервера."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "server.local"
        field.setAccessibilityLabel("Адрес SMB-сервера")
        alert.accessoryView = field
        alert.addButton(withTitle: "Открыть")
        alert.addButton(withTitle: "Отмена")
        alert.addButton(withTitle: "Войти как…")
        alert.window.initialFirstResponder = field
        switch alert.runModal() {
        case .alertFirstButtonReturn: openServer(field.stringValue)
        case .alertThirdButtonReturn: openServer(field.stringValue, explicit: true)
        default: break
        }
        focus()
    }

    @objc private func refreshButtonPressed() { refresh(); focus() }
    @objc private func cancelButtonPressed() { cancelOrClose(); focus() }
    @objc private func doubleClick() {
        if table.clickedRow >= 0 { openSelection() }
    }

    private func begin(_ description: String, cancellable: Bool = true) -> UUID {
        let token = UUID()
        operation = token
        cancelButton.isHidden = !cancellable
        showStatus(description)
        return token
    }

    private func end(_ token: UUID) -> Bool {
        guard started, operation == token else { return false }
        operation = nil
        disconnecting = false
        cancelButton.isHidden = true
        return true
    }

    private func cancelRequest() {
        operation = nil
        disconnecting = false
        resolver.stop()
        listing.stop()
        mount.stop()
        cancelButton.isHidden = true
    }

    private func cancelOrClose() {
        guard !disconnecting else { return }
        if operation != nil {
            cancelRequest()
            showStatus("Операция отменена.")
        } else {
            onClose?()
        }
    }

    private func showStatus(_ value: String) {
        status.stringValue = value
        status.toolTip = value
    }

    private func reload(preferred: Row? = nil) {
        let previous = preferred ?? cursor
        rows = [.up] + (server?.shares.map(Row.share) ?? discovered.map(Row.server))
        table.reloadData()
        let row = previous.flatMap { rows.firstIndex(of: $0) } ?? (rows.count > 1 ? 1 : 0)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func key(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags == .control, event.charactersIgnoringModifiers?.lowercased() == "r" { refresh(); return true }
        if flags == .shift && event.keyCode == 96 { return performFunction(5) }
        guard flags.isEmpty else { return false }
        switch event.keyCode {
        case 36, 76: openSelection()
        case 48: onSwitchPanel?()
        case 51: goUp()
        case 53: cancelOrClose()
        case 99: return performFunction(3)
        case 118: return performFunction(4)
        case 96: return performFunction(5)
        case 97: return performFunction(6)
        case 100, 117: return performFunction(8)
        default: return false
        }
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = FileRow()
        view.active = active
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let title: String
        switch rows[row] {
        case .up: title = "↰  .."
        case .server(let advertisement): title = "▸  " + advertisement.name
        case .share(let share): title = (mounted[share] == nil ? "▸  " : "✓  ") + share.name
        }
        let field = label(title, size: 12)
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }
}
