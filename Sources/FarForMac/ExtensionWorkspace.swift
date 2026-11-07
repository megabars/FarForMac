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
        ("EditCase: ПРОПИСНЫЕ", "editcase-upper", .editor),
        ("EditCase: строчные", "editcase-lower", .editor),
        ("EditCase: Каждое Слово С Прописной", "editcase-title", .editor),
        ("EditCase: иНВЕРСИЯ рЕГИСТРА", "editcase-toggle", .editor),
        ("EditCase: циклическая смена регистра", "editcase-cyclic", .editor),
        ("Align: форматировать выделенный блок…", "align", .editor)
    ]
    func installMenu(in bar: NSMenu) {
        let root = NSMenuItem(title: "Расширения", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: root.title); root.submenu = menu; bar.addItem(root)
        let brackets = NSMenuItem(title: "Парные скобки…", action: #selector(showBrackets), keyEquivalent: "")
        brackets.target = self; menu.addItem(brackets)
        menu.addItem(.separator())
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
        if item.action == #selector(showBrackets) { return NSApp.keyWindow?.windowController is TextFileWindow }
        if item.action == #selector(runExample(_:)) {
            let kind = examples[item.tag].2
            let context = CommandWorkspace.shared.context
            if kind == .panel { return context == .panel }
            if kind == .editor { return (NSApp.keyWindow?.windowController as? TextFileWindow)?.isEditable == true }
            return context == .editor || context == .viewer
        }
        return CommandWorkspace.shared.context != .dialog
    }
    @objc private func showBrackets() {
        guard let editor = NSApp.keyWindow?.windowController as? TextFileWindow else { return }
        BracketsWorkspace.show(for: editor)
    }
    func showEditorPlugins(_ editor: TextFileWindow, selectedAction: Int? = nil) {
        guard !isRunning, !CommandWorkspace.shared.macros.isPlaying else { return }
        var selected = selectedAction
        if selected == nil {
            let menu = PanelListMenu(title: "Команды плагинов", hint: "Enter — выполнить · Esc — отмена")
            menu.replaceRows([.init(title: "Парные скобки"), .init(title: "EditCase", selectable: editor.isEditable), .init(title: "Align", selectable: editor.isEditable)])
            menu.onActivate = { selected = $0; menu.dismiss() }
            menu.run(relativeTo: editor.window); menu.onActivate = nil
        }
        if selected == 0 { BracketsWorkspace.show(for: editor) }
        if selected == 1 {
            let choices = examples.enumerated().filter { $0.element.1.hasPrefix("editcase-") }
            let actions = PanelListMenu(title: "EditCase", hint: "Enter — выполнить · Esc — отмена")
            actions.replaceRows(choices.map { .init(title: $0.element.0) })
            var chosen: Int?
            actions.onActivate = { chosen = choices[$0].offset; actions.dismiss() }
            defer { actions.onActivate = nil }
            actions.run(relativeTo: editor.window)
            if let chosen { let item = NSMenuItem(); item.tag = chosen; runExample(item) }
        }
        if selected == 2, let index = examples.firstIndex(where: { $0.1 == "align" }) {
            let item = NSMenuItem(); item.tag = index; runExample(item)
        }
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
        do {
            let options: ExtensionTextOptions?
            if example.1 == "align" {
                guard let configured = configureAlign() else { return }
                options = configured
            } else { options = nil }
            try start(ExtensionDescriptor(id: "builtin." + example.1, title: example.0, kind: example.2, executableURL: bundledScript(), arguments: [example.1]), options: options)
        }
        catch { report(error) }
    }
    private func configureAlign() -> ExtensionTextOptions? {
        let owner = NSApp.keyWindow
        let tabSize = (owner?.windowController as? TextFileWindow)?.extensionTabSize ?? 8
        let defaults = AppPreferences.defaults
        let width = NSTextField(string: String(defaults.object(forKey: "extension.align.width") as? Int ?? 75))
        let reformat = NSButton(checkboxWithTitle: L10n.text("Переформатировать выделенный блок в абзац"), target: nil, action: nil)
        let smart = NSButton(checkboxWithTitle: L10n.text("SmartMode: переносить короткие слова с конца строки"), target: nil, action: nil)
        let justify = NSButton(checkboxWithTitle: L10n.text("Выровнять по правому краю"), target: nil, action: nil)
        reformat.state = defaults.object(forKey: "extension.align.reformat") as? Bool == false ? .off : .on
        smart.state = defaults.bool(forKey: "extension.align.smart") ? .on : .off
        justify.state = defaults.bool(forKey: "extension.align.justify") ? .on : .off
        let stack = NSStackView(views: [NSTextField(labelWithString: L10n.text("Правая граница (1–1000 символов):")), width, reformat, smart, justify])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.setFrameSize(NSSize(width: 480, height: 145))
        let alert = NSAlert(); alert.messageText = L10n.text("Align: параметры блока")
        alert.informativeText = L10n.text("Обрабатываются целые выделенные строки. Переформатирование объединяет их в один абзац, пропуская пустые строки. Ширина считается по символам Unicode. Размер табуляции:") + " \(tabSize)."
        alert.accessoryView = stack; alert.addButton(withTitle: L10n.text("Предпросмотр")); alert.addButton(withTitle: L10n.text("Отмена"))
        defer { owner?.makeKeyAndOrderFront(nil) }
        while alert.runModal() == .alertFirstButtonReturn {
            guard let margin = Int(width.stringValue), (1...1000).contains(margin) else { NSSound.beep(); width.selectText(nil); continue }
            defaults.set(margin, forKey: "extension.align.width")
            defaults.set(reformat.state == .on, forKey: "extension.align.reformat")
            defaults.set(smart.state == .on, forKey: "extension.align.smart")
            defaults.set(justify.state == .on, forKey: "extension.align.justify")
            return ExtensionTextOptions(rightMargin: margin, reformat: reformat.state == .on, smartMode: smart.state == .on, justify: justify.state == .on, tabSize: tabSize)
        }
        return nil
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
    private func start(_ descriptor: ExtensionDescriptor, options: ExtensionTextOptions? = nil) throws {
        guard cancellation == nil else { throw ExtensionAPIError("Расширение уже работает.") }
        let editor = NSApp.keyWindow?.windowController as? TextFileWindow
        let viewer = NSApp.keyWindow?.windowController as? ViewerWindow
        let revision = editor?.extensionRevision
        let snapshot: ExtensionEditorSnapshot?
        if descriptor.kind == .editor, let editor {
            let scope: ExtensionEditorSnapshot.Scope = descriptor.id.hasPrefix("builtin.editcase-") ? .selectionOrWord : (descriptor.id == "builtin.align" ? .selectedLines : .document)
            snapshot = try ExtensionEditorSnapshot(text: editor.extensionText, selection: editor.extensionSelection, scope: scope)
        } else { snapshot = nil }
        let request: ExtensionRequest
        if descriptor.kind == .panel {
            guard CommandWorkspace.shared.context == .panel, let panelEntries else { throw ExtensionAPIError("Откройте локальную файловую панель.") }
            request = ExtensionRequest(kind: .panel, entries: try panelEntries())
        } else {
            if descriptor.kind == .editor, editor?.isEditable != true { throw ExtensionAPIError("Откройте редактируемый документ.") }
            guard let text = snapshot?.text ?? editor?.extensionText ?? viewer?.extensionText else { throw ExtensionAPIError("Откройте текст в редакторе или просмотрщике.") }
            guard text.utf8.count <= 512 * 1024 else { throw ExtensionAPIError("Текст для расширения ограничен 512 КиБ. Просмотрщик передаёт только видимый загруженный блок.") }
            request = ExtensionRequest(kind: descriptor.kind, text: text, options: options)
        }
        let token = ExtensionCancellation(); cancellation = token
        CommandWorkspace.shared.status?("Расширение «\(descriptor.title)» работает…")
        Task { [weak self, weak editor] in
            do {
                let result = try await Task.detached(priority: .userInitiated) { try ExtensionHost().invoke(descriptor, request: request, cancellation: token) }.value
                guard let self else { return }
                self.cancellation = nil
                guard !token.isCancelled else { return }
                self.present(result.response, editor: editor, revision: revision, snapshot: snapshot)
                CommandWorkspace.shared.status?("Расширение «\(descriptor.title)» завершено.")
            } catch {
                self?.cancellation = nil
                if !token.isCancelled { self?.report(error) }
                CommandWorkspace.shared.status?(token.isCancelled ? "Расширение остановлено." : "Ошибка расширения: \(error.localizedDescription)")
            }
        }
    }
    @discardableResult
    private func present(_ response: ExtensionResponse, editor: TextFileWindow?, revision: Int?, snapshot: ExtensionEditorSnapshot?) -> ExtensionResultWindow {
        let controller = ExtensionResultWindow(response: response) { [weak editor] in
            guard let editor, let revision, let text = response.text else { throw ExtensionAPIError("Редактор закрыт.") }
            let replacement = try snapshot?.replacing(with: text, currentText: editor.extensionText) ?? text
            try editor.applyExtensionText(replacement, revision: revision, title: response.title)
        }
        windows.removeAll { $0.window?.isVisible != true }; windows.append(controller); controller.showWindow(nil)
        return controller
    }
    /// Real AppKit preview/apply/Undo path, using only the isolated smoke fixture.
    static func runUISmokeChecks() throws -> [String] {
        guard AppRuntime.isSmoke, let directory = AppRuntime.smokeStateDirectory else { throw ExtensionAPIError("Extension smoke requires isolated state.") }
        let url = directory.appendingPathComponent("extension-selection.txt")
        let original = "before ßeta after\r\nsecond line\r\n"
        try Data(original.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let editor = try TextFileWindow(url: url)
        editor.showWindow(nil)
        defer { editor.closeArchiveWorkingCopyWithoutSaving() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        guard let content = editor.window?.contentView,
              let textView = descendants(content).compactMap({ $0 as? NSTextView }).first else { throw ExtensionAPIError("Missing editor text view.") }
        textView.setSelectedRange((original as NSString).range(of: "ßeta"))
        let snapshot = try ExtensionEditorSnapshot(text: editor.extensionText, selection: editor.extensionSelection, scope: .selectionOrWord)
        let revision = editor.extensionRevision
        let workspace = ExtensionWorkspace()
        let preview = workspace.present(ExtensionResponse(kind: .editor, title: "Selection smoke", text: "SSETA"), editor: editor, revision: revision, snapshot: snapshot)
        defer { preview.close() }
        guard editor.extensionText == original else { throw ExtensionAPIError("Preview changed the editor before Apply.") }
        textView.setSelectedRange((original as NSString).range(of: "second"))
        guard let previewContent = preview.window?.contentView,
              let apply = descendants(previewContent).compactMap({ $0 as? NSButton }).first else { throw ExtensionAPIError("Missing extension Apply button.") }
        apply.performClick(nil)
        guard editor.extensionText == "before SSETA after\r\nsecond line\r\n", !apply.isEnabled else {
            throw ExtensionAPIError("Apply must replace the captured range once, including Unicode length expansion.")
        }
        textView.undoManager?.undo()
        guard editor.extensionText == original else { throw ExtensionAPIError("Extension Undo must restore the entire original buffer.") }
        // Undo restored equal bytes, but the document revision still makes the
        // older asynchronous proposal stale. The production Apply guard rejects it.
        do {
            try editor.applyExtensionText(try snapshot.replacing(with: "STALE", currentText: editor.extensionText), revision: revision, title: "Stale smoke")
            throw ExtensionAPIError("A stale extension revision was accepted after Undo.")
        } catch {
            guard editor.extensionText == original, editor.extensionRevision != revision else { throw error }
        }
        return ["Extension preview leaves editor unchanged until Apply", "Extension Apply uses captured selection despite later cursor movement", "Unicode extension replacement applies once and Undo restores original EOL", "Extension stale revision is rejected after Undo"]
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
