import AppKit
import FarCore

@MainActor
final class StockPanelPlugins {
    static let shared = StockPanelPlugins()
    private init() {}

    private static let fileCaseKey = "plugins.fileCase.options"
    private static let sameFolderKey = "plugins.sameFolder.options"
    private var worker: Task<Void, Never>?
    private var cancellation: FileToolCancellation?
    var isApplyingFileCase: Bool { worker != nil }

    struct SameFolderOptions: Codable, Equatable {
        var pluginMenu = true
        var disksMenu = false
    }

    var sameFolderOptions: SameFolderOptions {
        get {
            guard let data = AppPreferences.defaults.data(forKey: Self.sameFolderKey),
                  let options = try? JSONDecoder().decode(SameFolderOptions.self, from: data) else { return .init() }
            return options
        }
        set { AppPreferences.defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.sameFolderKey) }
    }

    func menuEntries(app: AppDelegate, area: String) -> [(title: String, activate: () -> Void)] {
        guard area == "Shell", let source = app.active else { return [] }
        var entries: [(String, () -> Void)] = []
        if Self.isLocalFiles(source) {
            entries.append((L10n.text("Преобразование регистра"), { [weak self, weak app, weak source] in
                guard let self, let app, let source else { return }
                self.openFileCase(source, app: app)
            }))
            if sameFolderOptions.pluginMenu, let destination = source === app.left ? app.right : app.left,
               Self.isLocalFiles(destination) {
                entries.append((L10n.text("Такая же папка"), { [weak self, weak app, weak source, weak destination] in
                    guard let self, let app, let source, let destination else { return }
                    self.openSameFolder(from: source, to: destination, app: app)
                }))
            }
        }
        return entries
    }

    func diskMenuEntry(app: AppDelegate, panel: PanelView) -> (title: String, activate: () -> Void)? {
        guard sameFolderOptions.disksMenu, Self.isLocalFiles(panel) else { return nil }
        let source = panel === app.left ? app.right : app.left
        guard let source, Self.isLocalFiles(source) else { return nil }
        return (L10n.text("Такая же папка"), { [weak self, weak app, weak panel, weak source] in
            guard let self, let app, let panel, let source else { return }
            self.openSameFolder(from: source, to: panel, app: app)
        })
    }

    func configureSameFolder() {
        let options = sameFolderOptions
        let pluginMenu = checkbox("Добавить «Такая же папка» в меню плагинов", options.pluginMenu)
        let disksMenu = checkbox("Добавить «Такая же папка» в меню дисков", options.disksMenu)
        let form = vertical([pluginMenu, disksMenu], spacing: 8)
        let alert = NSAlert()
        alert.messageText = L10n.text("Настройка «Такая же папка»")
        alert.accessoryView = accessory(form, size: NSSize(width: 440, height: 52))
        alert.addButton(withTitle: L10n.text("OK"))
        alert.addButton(withTitle: L10n.text("Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        sameFolderOptions = .init(pluginMenu: pluginMenu.state == .on, disksMenu: disksMenu.state == .on)
    }

    func cancelFileCase() { cancellation?.cancel() }

    private func openFileCase(_ panel: PanelView, app: AppDelegate) {
        guard !isApplyingFileCase, app.canChangePanelResource, Self.isLocalFiles(panel), !panel.loading else { return }
        let items = panel.selectedEntries.map(\.url)
        guard !items.isEmpty else { NSSound.beep(); return }
        let current = panel.cursorEntry
        let directory = panel.directory
        let generation = panel.locationGeneration
        let saved = AppPreferences.defaults.data(forKey: Self.fileCaseKey).flatMap { try? JSONDecoder().decode(FileCaseOptions.self, from: $0) }
        guard let (options, currentRunOnly) = FileCaseDialog(options: saved ?? .init()).run(),
              options.name != .unchanged || options.fileExtension != .unchanged else { return }
        guard app.canChangePanelResource, panel.locationGeneration == generation else { return }
        if !currentRunOnly {
            AppPreferences.defaults.set(try? JSONEncoder().encode(options), forKey: Self.fileCaseKey)
        }
        let token = FileToolCancellation()
        cancellation = token
        app.status.stringValue = L10n.text("Преобразование регистра…")
        worker = Task { [weak self, weak app, weak panel] in
            defer { self?.worker = nil; self?.cancellation = nil }
            do {
                let changed = try await Task.detached(priority: .userInitiated) {
                    try FileCase.rename(items, options: options, cancellation: token)
                }.value
                app?.status.stringValue = L10n.text("Переименовано") + " \(changed)"
            } catch is CancellationError {
                app?.status.stringValue = L10n.text("Преобразование регистра отменено.")
            } catch {
                app?.status.stringValue = error.localizedDescription
            }
            if let panel, panel.locationGeneration == generation {
                let name = current.map { FileCase.convertedName($0.name, isDirectory: $0.isDirectory, options: options) }
                panel.load(preserveSelection: false, selectName: name)
            }
            if let app, let other = panel === app.left ? app.right : app.left,
               Self.isLocalFiles(other), other.directory == directory, !other.loading { other.refresh() }
        }
    }

    private func openSameFolder(from source: PanelView, to destination: PanelView, app: AppDelegate) {
        guard app.canChangePanelResource, Self.isLocalFiles(source), Self.isLocalFiles(destination),
              !source.loading, !destination.loading else { return }
        Self.copyFolder(from: source, to: destination, completion: nil)
    }

    private static func isLocalFiles(_ panel: PanelView) -> Bool {
        panel.contentMode == .files && !panel.isArchive && !panel.isRemote && !panel.isResource && !panel.isVirtual && !panel.isTemporary
    }

    private static func copyFolder(from source: PanelView, to destination: PanelView, completion: ((Bool) -> Void)?) {
        let entry = source.cursorEntry
        destination.navigateHistory(to: source.directory.path, focus: false) { [weak destination] loaded in
            guard loaded, let destination else { completion?(false); return }
            let index: Int
            if let entry, let match = (0..<destination.table.numberOfRows).first(where: { row in
                guard let value = destination.entry(at: row) else { return false }
                return value.name == entry.name && value.size == entry.size && value.isDirectory == entry.isDirectory
                    && value.isSymbolicLink == entry.isSymbolicLink && value.created == entry.created
                    && value.accessed == entry.accessed && value.modified == entry.modified
                    && value.permissions == entry.permissions && value.owner == entry.owner
            }) { index = match }
            else { index = 0 }
            if destination.table.numberOfRows > 0 {
                let state: FarLuaValue = .table(["CurrentItem": .integer(Int64(index + 1)), "TopPanelItem": .integer(Int64(index + 1))])
                _ = try? destination.luaPanelCall("panel.RedrawPanel", [.nilValue, .integer(1), state])
                if let scroll = destination.table.enclosingScrollView {
                    let clip = scroll.contentView
                    clip.scroll(to: NSPoint(x: clip.bounds.minX, y: destination.table.rect(ofRow: index).minY))
                    scroll.reflectScrolledClipView(clip)
                }
            }
            completion?(true)
        }
    }

    private func checkbox(_ title: String, _ checked: Bool) -> NSButton {
        let button = NSButton(checkboxWithTitle: L10n.text(title), target: nil, action: nil)
        button.state = checked ? .on : .off
        return button
    }

    private func accessory(_ content: NSView, size: NSSize) -> NSView {
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                                     content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                                     content.topAnchor.constraint(equalTo: view.topAnchor)])
        return view
    }
}

@MainActor
private final class FileCaseDialog: NSObject {
    private let name: NSMatrix
    private let fileExtension: NSMatrix
    private let mixed = NSButton(checkboxWithTitle: "Не обрабатывать файлы со смешанным регистром", target: nil, action: nil)
    private let recurse = NSButton(checkboxWithTitle: "Обрабатывать вложенные папки", target: nil, action: nil)
    private let directories = NSButton(checkboxWithTitle: "Обрабатывать имена папок", target: nil, action: nil)
    private let current = NSButton(checkboxWithTitle: "Только для текущего преобразования", target: nil, action: nil)
    private let delimiters: NSTextField

    init(options: FileCaseOptions) {
        name = Self.choice(options.name, firstShortcut: 1)
        fileExtension = Self.choice(options.fileExtension, firstShortcut: 6)
        delimiters = NSTextField(string: options.wordDelimiters)
        super.init()
        mixed.state = options.skipMixedCase ? .on : .off
        recurse.state = options.recurse ? .on : .off
        directories.state = options.renameDirectories ? .on : .off
        delimiters.setAccessibilityLabel("Символы-разделители слов")
    }

    private static func choice(_ mode: FileCaseMode, firstShortcut: Int) -> NSMatrix {
        let radio = NSButtonCell(textCell: "")
        radio.setButtonType(.radio)
        let control = NSMatrix(frame: .zero, mode: .radioModeMatrix, prototype: radio, numberOfRows: 5, numberOfColumns: 1)
        control.cellSize = NSSize(width: 220, height: 20)
        let titles = ["все строчные", "ВСЕ ПРОПИСНЫЕ", "Первая прописная", "Начинать С Прописных", "Не менять"]
        for (index, title) in titles.enumerated() {
            let key = String((firstShortcut + index) % 10)
            if let cell = control.cell(atRow: index, column: 0) as? NSButtonCell {
                cell.title = key + ". " + title
                cell.keyEquivalent = key
            }
        }
        control.selectCell(atRow: mode.rawValue, column: 0)
        control.sizeToCells()
        return control
    }

    fileprivate var options: FileCaseOptions {
        .init(name: FileCaseMode(rawValue: name.selectedRow) ?? .lower,
              fileExtension: FileCaseMode(rawValue: fileExtension.selectedRow) ?? .lower,
              skipMixedCase: mixed.state == .on, recurse: recurse.state == .on,
              renameDirectories: directories.state == .on, wordDelimiters: delimiters.stringValue)
    }

    func run() -> (FileCaseOptions, Bool)? {
        let reset = NSButton(title: "Сброс", target: self, action: #selector(resetWords))
        let columns = horizontal([vertical([NSTextField(labelWithString: "Имя"), name]),
                                  vertical([NSTextField(labelWithString: "Расширение"), fileExtension])], spacing: 20)
        let content = vertical([columns, mixed, recurse, directories, current,
                                NSTextField(labelWithString: "Символы-разделители слов"), horizontal([delimiters, reset])], spacing: 8)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 265))
        content.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(content)
        NSLayoutConstraint.activate([content.topAnchor.constraint(equalTo: accessory.topAnchor),
                                     content.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
                                     content.trailingAnchor.constraint(equalTo: accessory.trailingAnchor)])
        let alert = NSAlert()
        alert.messageText = "Преобразование регистра"
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Продолжить")
        alert.addButton(withTitle: "Отменить")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return (options, current.state == .on)
    }

    @objc fileprivate func resetWords() { delimiters.stringValue = FileCaseOptions.defaultWordDelimiters }
}

extension StockPanelPlugins {
    static func runUISmokeChecks(in root: URL) async throws -> [String] {
        let stock = Self.shared
        let previous = AppPreferences.defaults.data(forKey: Self.sameFolderKey)
        defer {
            if let previous { AppPreferences.defaults.set(previous, forKey: Self.sameFolderKey) }
            else { AppPreferences.defaults.removeObject(forKey: Self.sameFolderKey) }
        }
        let directory = root.appendingPathComponent("stock-panel-plugins-" + UUID().uuidString, isDirectory: true)
        let leftURL = directory.appendingPathComponent("left", isDirectory: true)
        let rightURL = directory.appendingPathComponent("right", isDirectory: true)
        try FileManager.default.createDirectory(at: leftURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rightURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for parent in [leftURL, rightURL] {
            try Data("one".utf8).write(to: parent.appendingPathComponent("one.txt"))
            try Data("two".utf8).write(to: parent.appendingPathComponent("two.txt"))
        }
        let app = AppDelegate()
        app.left = PanelView(directory: leftURL, key: "stock-left-" + UUID().uuidString)
        app.right = PanelView(directory: rightURL, key: "stock-right-" + UUID().uuidString)
        app.active = app.left
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = horizontal([app.left, app.right])
        defer { window.contentView = nil; window.close() }
        func load(_ panel: PanelView, _ url: URL) async -> Bool {
            await withCheckedContinuation { continuation in
                panel.navigateHistory(to: url.path, focus: false) { continuation.resume(returning: $0) }
            }
        }
        func wait(_ panel: PanelView) async throws {
            let deadline = Date().addingTimeInterval(5)
            while panel.loading, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            if panel.loading { throw PanelSessionError("SameFolder navigation timed out") }
        }
        guard await load(app.left, leftURL), await load(app.right, rightURL) else {
            throw PanelSessionError("SameFolder fixture directories could not load")
        }
        let right = app.right!, left = app.left!
        stock.sameFolderOptions = .init()
        let entries = stock.menuEntries(app: app, area: "Shell")
        guard entries.count == 2, stock.diskMenuEntry(app: app, panel: right) == nil,
              stock.menuEntries(app: app, area: "Editor").isEmpty else {
            throw PanelSessionError("SameFolder default routes and FileCase panel context differ from FAR")
        }
        let move: [FarLuaValue] = [.nilValue, .integer(1), .table(["CurrentItem": .integer(3)])]
        _ = try left.luaPanelCall("panel.RedrawPanel", move)
        entries[1].activate()
        try await wait(right)
        guard right.directory.resolvingSymlinksInPath().path == leftURL.resolvingSymlinksInPath().path, right.cursorEntry?.name == left.cursorEntry?.name, app.active === left else {
            throw PanelSessionError("SameFolder F11 must move the passive panel and copy the source cursor")
        }
        guard await load(right, rightURL) else { throw PanelSessionError("SameFolder could not restore fixture") }
        _ = try right.luaPanelCall("panel.RedrawPanel", move)
        stock.sameFolderOptions = .init(pluginMenu: false, disksMenu: true)
        guard stock.menuEntries(app: app, area: "Shell").count == 1,
              let disk = stock.diskMenuEntry(app: app, panel: left) else {
            throw PanelSessionError("SameFolder menu options must apply independently")
        }
        app.active = right
        disk.activate()
        try await wait(left)
        guard left.directory.resolvingSymlinksInPath().path == rightURL.resolvingSymlinksInPath().path, left.cursorEntry?.name == right.cursorEntry?.name, app.active === right else {
            throw PanelSessionError("SameFolder disk menu must use the chosen side after focus changes")
        }

        app.active = left
        stock.sameFolderOptions = .init(pluginMenu: true, disksMenu: true)
        guard let staleDisk = stock.diskMenuEntry(app: app, panel: right) else {
            throw PanelSessionError("SameFolder must offer a local target in the disk menu")
        }
        let virtualItem = try SearchResult.capture(rightURL.appendingPathComponent("one.txt"))
        try right.showVirtualResults([.local(virtualItem)], focusPanel: false)
        entries[1].activate()
        staleDisk.activate()
        guard stock.menuEntries(app: app, area: "Shell").count == 1,
              stock.diskMenuEntry(app: app, panel: right) == nil, right.isVirtual,
              right.luaPanelProperties.hostTable["Current"]?.hostString == virtualItem.name else {
            throw PanelSessionError("SameFolder must hide both routes for a provider target and preserve it on stale activation")
        }

        let auxiliaryChecks = try left.runLuaAuxiliaryPanelSmokeChecks()

        let options = FileCaseOptions(name: .title, fileExtension: .upper, skipMixedCase: false,
                                      recurse: true, renameDirectories: true, wordDelimiters: "-")
        let dialog = FileCaseDialog(options: options)
        guard dialog.options == options else { throw PanelSessionError("FileCase controls did not reflect saved settings") }
        dialog.resetWords()
        var reset = options; reset.wordDelimiters = FileCaseOptions.defaultWordDelimiters
        guard dialog.options == reset else { throw PanelSessionError("FileCase reset must change only word delimiters") }
        return ["SameFolder F11 and disk actions copy the intended side's directory and cursor",
                "SameFolder settings independently enable both menus",
                "SameFolder keeps a provider panel intact when a stale menu action is invoked",
                "FileCase AppKit dialog preserves independent conversions and resets only delimiters"] + auxiliaryChecks
    }
}
