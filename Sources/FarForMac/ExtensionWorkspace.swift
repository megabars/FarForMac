import AppKit
import FarCore

/// Explicit invocation and presentation of immutable extension inputs/results.
@MainActor
final class ExtensionWorkspace: NSObject, NSMenuItemValidation {
    static let shared = ExtensionWorkspace()
    var panelEntries: (() throws -> [ExtensionEntry])?
    private var cancellation: ExtensionCancellation?
    private var windows: [NSWindowController] = []
    var isRunning: Bool { cancellation != nil }
    private let examples: [(String, String, ExtensionKind)] = [
        ("SHA-256 текста", "checksum", .command),
        ("Статистика выбранных файлов", "stats", .panel),
        ("Просмотр JSON с форматированием", "json", .viewer),
        ("EditCase: ASCII ПРОПИСНЫЕ", "editcase-upper", .editor),
        ("EditCase: ASCII строчные", "editcase-lower", .editor),
        ("Align: выравнивание ASCII до 75 колонок", "align", .editor)
    ]
    func installMenu(in bar: NSMenu) {
        let root = NSMenuItem(title: "Расширения", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: root.title); root.submenu = menu; bar.addItem(root)
        for (index, entry) in examples.enumerated() {
            let item = NSMenuItem(title: entry.0, action: #selector(runExample(_:)), keyEquivalent: "")
            item.tag = index; item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())
        let custom = NSMenuItem(title: "Запустить расширение по описанию…", action: #selector(runCustom), keyEquivalent: ""); custom.target = self; menu.addItem(custom)
        let stop = NSMenuItem(title: "Остановить расширение", action: #selector(cancel), keyEquivalent: ""); stop.target = self; menu.addItem(stop)
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(cancel) { return isRunning }
        guard !isRunning, !CommandWorkspace.shared.macros.isPlaying, NSApp.modalWindow == nil, NSApp.keyWindow?.attachedSheet == nil else { return false }
        if item.action == #selector(runExample(_:)) {
            let kind = examples[item.tag].2
            let context = CommandWorkspace.shared.context
            if kind == .panel { return context == .panel }
            if kind == .editor { return (NSApp.keyWindow?.windowController as? TextFileWindow)?.isEditable == true }
            return context == .editor || context == .viewer
        }
        return CommandWorkspace.shared.context != .dialog
    }
    @objc func cancel() { cancellation?.cancel() }
    private func bundledScript() throws -> URL {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Extensions/text-tools.py")
        if let bundled, FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        // SwiftPM development launch: resolve against this source's workspace, never cwd.
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Examples/Extensions/text-tools.py")
        guard FileManager.default.isExecutableFile(atPath: source.path) else { throw ExtensionAPIError("Примеры расширений отсутствуют. Пересоберите приложение.") }
        return source
    }
    @objc private func runExample(_ sender: NSMenuItem) {
        let example = examples[sender.tag]
        do { try start(ExtensionDescriptor(id: "builtin." + example.1, title: example.0, kind: example.2, executableURL: bundledScript(), arguments: [example.1])) }
        catch { report(error) }
    }
    private struct Manifest: Decodable {
        let id: String
        let title: String
        let apiVersion: Int
        let kind: ExtensionKind
        let executable: String
        let arguments: [String]
    }
    @objc private func runCustom() {
        let owner = NSApp.keyWindow
        let panel = NSOpenPanel(); panel.title = "Описание расширения (JSON)"; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 65_536 else { throw ExtensionAPIError("Описание должно быть обычным JSON-файлом до 64 КиБ.") }
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let data = try handle.read(upToCount: 65_537) ?? Data()
            guard data.count <= 65_536 else { throw ExtensionAPIError("Описание слишком велико.") }
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard manifest.apiVersion == 1 else { throw ExtensionAPIError("Несовместимая версия API. Поддерживается версия 1.") }
            guard manifest.executable.hasPrefix("/"), manifest.arguments.count <= 100, !manifest.title.isEmpty, manifest.title.count <= 256 else { throw ExtensionAPIError("Укажите абсолютный путь к программе и корректные параметры.") }
            let alert = NSAlert(); alert.messageText = "Запустить «\(manifest.title)»?"
            alert.informativeText = "Программа: \(manifest.executable)\nПараметры: \(manifest.arguments.joined(separator: " "))\nТип: \(manifest.kind.rawValue)\n\nПрограмма получит текст текущего окна или список выбранных файлов. Она выполняется с вашими правами macOS; запускайте только доверенные программы. Автоматической загрузки нет."
            alert.addButton(withTitle: "Запустить"); alert.addButton(withTitle: "Отмена")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            owner?.makeKeyAndOrderFront(nil)
            try start(ExtensionDescriptor(id: manifest.id, title: manifest.title, apiVersion: manifest.apiVersion, kind: manifest.kind, executableURL: URL(fileURLWithPath: manifest.executable), arguments: manifest.arguments))
        } catch { report(error) }
    }
    private func start(_ descriptor: ExtensionDescriptor) throws {
        guard cancellation == nil else { throw ExtensionAPIError("Расширение уже работает.") }
        let editor = NSApp.keyWindow?.windowController as? TextFileWindow
        let viewer = NSApp.keyWindow?.windowController as? ViewerWindow
        let revision = editor?.extensionRevision
        let request: ExtensionRequest
        if descriptor.kind == .panel {
            guard CommandWorkspace.shared.context == .panel, let panelEntries else { throw ExtensionAPIError("Откройте локальную файловую панель.") }
            request = ExtensionRequest(kind: .panel, entries: try panelEntries())
        } else {
            if descriptor.kind == .editor, editor?.isEditable != true { throw ExtensionAPIError("Откройте редактируемый документ.") }
            guard let text = editor?.extensionText ?? viewer?.extensionText else { throw ExtensionAPIError("Откройте текст в редакторе или просмотрщике.") }
            guard text.utf8.count <= 512 * 1024 else { throw ExtensionAPIError("Текст для расширения ограничен 512 КиБ. Просмотрщик передаёт только видимый загруженный блок.") }
            request = ExtensionRequest(kind: descriptor.kind, text: text)
        }
        let token = ExtensionCancellation(); cancellation = token
        CommandWorkspace.shared.status?("Расширение «\(descriptor.title)» работает…")
        Task { [weak self, weak editor] in
            do {
                let result = try await Task.detached(priority: .userInitiated) { try ExtensionHost().invoke(descriptor, request: request, cancellation: token) }.value
                guard let self else { return }
                self.cancellation = nil
                guard !token.isCancelled else { return }
                self.present(result.response, editor: editor, revision: revision)
                CommandWorkspace.shared.status?("Расширение «\(descriptor.title)» завершено.")
            } catch {
                self?.cancellation = nil
                if !token.isCancelled { self?.report(error) }
                CommandWorkspace.shared.status?(token.isCancelled ? "Расширение остановлено." : "Ошибка расширения: \(error.localizedDescription)")
            }
        }
    }
    private func present(_ response: ExtensionResponse, editor: TextFileWindow?, revision: Int?) {
        let controller = ExtensionResultWindow(response: response) { [weak editor] in
            guard let editor, let revision, let text = response.text else { throw ExtensionAPIError("Редактор закрыт.") }
            try editor.applyExtensionText(text, revision: revision, title: response.title)
        }
        windows.removeAll { $0.window?.isVisible != true }; windows.append(controller); controller.showWindow(nil)
    }
    private func report(_ error: Error) {
        let alert = NSAlert(); alert.messageText = "Расширение не выполнено"; alert.informativeText = error.localizedDescription; alert.addButton(withTitle: "Закрыть"); alert.runModal()
    }
}

@MainActor
private final class ExtensionResultWindow: NSWindowController {
    private let apply: () throws -> Void
    private var applied = false
    init(response: ExtensionResponse, apply: @escaping () throws -> Void) {
        self.apply = apply
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = (response.kind == .panel ? "Панель расширения: " : "Расширение: ") + response.title
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let text = NSTextView(); text.isEditable = false; text.isRichText = false; text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.string = response.kind == .panel ? response.rows.map { "\($0.label)\t\($0.value)" }.joined(separator: "\n") : response.text ?? ""
        text.autoresizingMask = [.width]; text.isVerticallyResizable = true
        let scroll = NSScrollView(); scroll.documentView = text; scroll.hasVerticalScroller = true
        text.minSize = NSSize(width: 0, height: 0); text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        let note = NSTextField(wrappingLabelWithString: response.kind == .editor ? "Предпросмотр. «Применить» изменяет буфер редактора с возможностью Undo; сохранение файла выполняется отдельно." : "Результат расширения доступен только для чтения.")
        let content = NSStackView(views: [note, scroll]); content.orientation = .vertical; content.alignment = .leading; content.spacing = 12; content.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        if response.kind == .editor {
            let button = NSButton(title: "Применить в редакторе", target: self, action: #selector(applyResult(_:))); content.addArrangedSubview(button)
        }
        window.contentView = content
        scroll.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -24).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func applyResult(_ sender: NSButton) {
        guard !applied else { return }
        do { try apply(); applied = true; sender.isEnabled = false; sender.title = "Применено — сохраните документ в редакторе" }
        catch { let alert = NSAlert(); alert.messageText = "Изменение не применено"; alert.informativeText = error.localizedDescription; alert.runModal() }
    }
}
