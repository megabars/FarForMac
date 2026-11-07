import AppKit
import FarCore

@MainActor
final class HlfViewerWorkspace {
    static let shared = HlfViewerWorkspace()
    static let guid = UUID(uuidString: "1AF0754D-5020-49CB-9474-1F82691C84C1")!
    private static let preferencesKey = "plugins.hlfViewer.options"

    private enum Source: Int, Codable { case saved, edited, saveThenShow }
    private enum EditorOutcome { case notApplicable, shown, failed(Error) }
    private struct Options: Codable {
        var processHotkey = true
        var hotkey = "F1"
        var checkMask = true
        var mask = "*.hlf"
        var source = Source.saved
    }

    private var options: Options {
        get {
            AppPreferences.defaults.data(forKey: Self.preferencesKey)
                .flatMap { try? JSONDecoder().decode(Options.self, from: $0) } ?? Options()
        }
        set { AppPreferences.defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.preferencesKey) }
    }

    private var browser: HlfViewerWindow?
    private(set) var lastFailure: String?

    func clearFailure() { lastFailure = nil }

    func isHelpWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return browser?.window === window
    }

    func handleKey(_ event: NSEvent) -> Bool {
        let window = event.window ?? NSApp.keyWindow
        guard NSApp.modalWindow == nil, window?.attachedSheet == nil else { return false }
        if isHelpWindow(window) { return browser?.handleKey(event) ?? false }
        return handleEditorKey(event)
    }

    func handleEditorKey(_ event: NSEvent) -> Bool {
        let options = options
        guard options.processHotkey, NSApp.modalWindow == nil, NSApp.keyWindow?.attachedSheet == nil,
              let editor = (event.window ?? NSApp.keyWindow)?.windowController as? TextFileWindow,
              (editor.window?.firstResponder as? NSTextView)?.hasMarkedText() != true,
              FarLuaKeys.name(event)?.caseInsensitiveCompare(options.hotkey) == .orderedSame else { return false }
        switch openEditorTopic(editor) {
        case .notApplicable: return false
        case .shown: return true
        case .failed(let error): report(error, relativeTo: editor.window); return true
        }
    }

    func menuEntry(for editor: TextFileWindow) -> (title: String, activate: () -> Void)? {
        guard !options.processHotkey else { return nil }
        return ("HlfViewer: показать текущую тему справки", { [weak self, weak editor] in
            guard let self, let editor else { return }
            switch self.openEditorTopic(editor) {
            case .shown: break
            case .notApplicable: self.report(FarHelpError.invalidDocument, relativeTo: editor.window)
            case .failed(let error): self.report(error, relativeTo: editor.window)
            }
        })
    }

    @discardableResult
    func showCurrentTopic(_ editor: TextFileWindow) -> Bool {
        if case .shown = openEditorTopic(editor) { return true }
        return false
    }

    private func openEditorTopic(_ editor: TextFileWindow) -> EditorOutcome {
        let settings = options
        let url = editor.workingFileURL
        if settings.checkMask, !settings.mask.isEmpty, let url,
           (try? FileMask(settings.mask).matchesChecked(url.lastPathComponent)) != true { return .notApplicable }
        let text = editor.extensionText
        guard let edited = try? FarHelpDocument(text) else { return .notApplicable }
        let line = FarEditorCoordinates(text).position(editor.extensionSelection.location).line - 1
        let current = edited.topic(atSourceLine: line)
        do {
            let document: FarHelpDocument
            switch settings.source {
            case .edited: document = edited
            case .saved, .saveThenShow:
                guard let url else { throw FarHelpError.unsupportedTarget("несохранённый файл") }
                if settings.source == .saveThenShow,
                   try editor.luaEditorCall("editor.SaveFile", [.nilValue]).first?.bool != true {
                    throw FarHelpError.unsupportedTarget("сохранение файла")
                }
                document = try HlfLocation.load(url)
            }
            let topic = try document.topic(named: current.name)
            show(.init(document: document, url: url), topic: topic.name,
                 scope: .init(directory: url?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser))
            return .shown
        } catch { return .failed(error) }
    }

    @discardableResult
    func executePrefix(_ prefix: String, _ arguments: String, directory: URL, farHome: URL? = nil,
                       pluginRoots: [UUID: URL] = [:]) -> Bool {
        guard prefix.caseInsensitiveCompare("hlf") == .orderedSame else { return false }
        clearFailure()
        let scope = HlfSearchScope(directory: directory, farHome: farHome, pluginRoots: pluginRoots)
        do {
            let (location, topic) = try scope.resolve(FarHelpInvocation(arguments: arguments))
            show(location, topic: try location.document.topic(named: topic).name, scope: scope)
        } catch { lastFailure = error.localizedDescription }
        return true
    }

    func showHelp(module: String?, topic: String?, flags: Int, directory: URL,
                  farHome: URL? = nil, pluginRoots: [UUID: URL] = [:]) throws -> Bool {
        guard flags & ~0xc000_000f == 0 else {
            throw FarHelpError.unsupportedTarget("far.ShowHelp flags \(flags)")
        }
        guard module?.utf8.contains(0) != true, topic?.utf8.contains(0) != true else { throw FarHelpError.invalidCommand }
        let scope = HlfSearchScope(directory: directory, farHome: farHome, pluginRoots: pluginRoots)
        do {
            let (location, name) = try scope.resolveModule(module: module, topic: topic, flags: flags)
            let page: FarHelpTopic
            do { page = try location.document.topic(named: name) }
            catch FarHelpError.missingTopic where flags & 0x4000_0000 != 0 { page = try location.document.topic() }
            show(location, topic: page.name, scope: scope)
            return true
        } catch {
            if flags & 0x8000_0000 == 0 { report(error, relativeTo: NSApp.keyWindow) }
            return false
        }
    }

    private func show(_ location: HlfLocation, topic: String, scope: HlfSearchScope) {
        let window = browser ?? HlfViewerWindow()
        browser = window
        window.open(location, topic: topic, scope: scope)
        window.showWindow(nil)
        window.window?.makeKeyAndOrderFront(nil)
    }

    private func report(_ error: Error, relativeTo window: NSWindow?) {
        let alert = NSAlert(error: error)
        if let window, window.attachedSheet == nil { alert.beginSheetModal(for: window) { _ in } }
        else { alert.runModal() }
    }

    func configure() {
        let settings = options
        let process = NSButton(checkboxWithTitle: "Обрабатывать нажатия клавиш в редакторе", target: nil, action: nil)
        process.state = settings.processHotkey ? .on : .off
        let hotkey = NSTextField(string: settings.hotkey)
        hotkey.setAccessibilityLabel("Горячая клавиша HlfViewer")
        let maskEnabled = NSButton(checkboxWithTitle: "Проверять по маске файлов", target: nil, action: nil)
        maskEnabled.state = settings.checkMask ? .on : .off
        let mask = NSTextField(string: settings.mask)
        mask.setAccessibilityLabel("Маска файлов HlfViewer")
        let version = NSPopUpButton(frame: .zero, pullsDown: false)
        version.addItems(withTitles: ["Показывать последний сохранённый файл", "Показывать изменённый файл", "Сохранять и показывать изменённый файл"])
        version.selectItem(at: settings.source.rawValue)
        let fields = vertical([horizontal([process, hotkey]), horizontal([maskEnabled, mask]),
                               NSTextField(labelWithString: "Показ редактируемого HLF-файла"), version], spacing: 8)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 120))
        fields.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(fields)
        NSLayoutConstraint.activate([fields.topAnchor.constraint(equalTo: accessory.topAnchor),
                                     fields.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
                                     fields.trailingAnchor.constraint(equalTo: accessory.trailingAnchor)])
        let alert = NSAlert()
        alert.messageText = "HlfViewer"
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = hotkey.stringValue.trimmingCharacters(in: .whitespaces)
        let pattern = mask.stringValue
        do {
            if process.state == .on { _ = try FarLuaKeys.event(key, window: nil) }
            if maskEnabled.state == .on, !pattern.isEmpty { _ = try FileMask(pattern) }
            options = Options(processHotkey: process.state == .on, hotkey: key,
                              checkMask: maskEnabled.state == .on, mask: pattern,
                              source: Source(rawValue: version.indexOfSelectedItem) ?? .saved)
        } catch { report(error, relativeTo: NSApp.keyWindow) }
    }
}

private struct HlfLocation {
    let document: FarHelpDocument
    let url: URL?

    static func load(_ url: URL) throws -> FarHelpDocument {
        try FarHelpDocument(EditorDocument.load(url: url).text)
    }
}

@MainActor
private struct HlfSearchScope {
    var directory: URL
    var farHome: URL? = nil
    var pluginRoots: [UUID: URL] = [:]

    func resolve(_ request: FarHelpInvocation) throws -> (HlfLocation, String?) {
        switch request {
        case .usage: return (try usage(), "cmd")
        case .hostTopic(let topic): return (try hostHelp(), topic)
        case .file(let path, let topic): return (try file(path), topic)
        case .nameOrTopic(let name):
            if let url = fileURL(name) { return (try HlfLocation(document: HlfLocation.load(url), url: url), nil) }
            return (try hostHelp(), name)
        case .plugin(let guid, let topic):
            if guid == HlfViewerWorkspace.guid { return (try usage(), topic) }
            if guid.uuidString == "00000000-0000-0000-0000-000000000000" {
                return (try hostHelp(), topic)
            }
            guard let root = pluginRoots[guid], let url = find(in: root) else {
                throw FarHelpError.unsupportedTarget(guid.uuidString)
            }
            return (try HlfLocation(document: HlfLocation.load(url), url: url), topic)
        }
    }

    func resolveModule(module: String?, topic: String?, flags: Int) throws -> (HlfLocation, String?) {
        if flags & 1 != 0 || topic?.hasPrefix(":") == true {
            let name = topic.map { $0.hasPrefix(":") ? String($0.dropFirst()) : $0 } ?? "Contents"
            return (try hostHelp(), name)
        }
        guard let module, !module.isEmpty else { throw FarHelpError.invalidCommand }
        if flags & 8 != 0 {
            let value = module.hasPrefix("{") && module.hasSuffix("}") ? String(module.dropFirst().dropLast()) : module
            guard let guid = UUID(uuidString: value) else { throw FarHelpError.invalidCommand }
            return try resolve(.plugin(guid, topic: topic))
        }
        if flags & 2 != 0 { return (try file(module), topic) }
        let path = (module as NSString).expandingTildeInPath
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)
        let root = flags & 4 != 0 ? url : url.deletingLastPathComponent()
        guard let help = find(in: root) else { throw FarHelpError.unsupportedTarget(module) }
        return (try HlfLocation(document: HlfLocation.load(help), url: help), topic)
    }

    func follow(_ target: FarHelpTarget, from source: HlfLocation) throws -> (HlfLocation, String?) {
        switch target {
        case .topic(let name): return (source, name)
        case .file(let path, let name):
            let url: URL
            if path.hasPrefix("/") { url = URL(fileURLWithPath: path) }
            else if let base = source.url { url = base.deletingLastPathComponent().appendingPathComponent(path) }
            else { throw FarHelpError.unsupportedTarget(path) }
            return (try HlfLocation(document: HlfLocation.load(url), url: url), name)
        case .host(let name): return (try hostHelp(), name)
        case .unsupported(let value): throw FarHelpError.unsupportedTarget(value)
        }
    }

    private func file(_ path: String) throws -> HlfLocation {
        guard let url = fileURL(path) else { throw FarHelpError.unsupportedTarget(path) }
        return try HlfLocation(document: HlfLocation.load(url), url: url)
    }

    private func fileURL(_ path: String) -> URL? {
        let name = (path.replacingOccurrences(of: "\\", with: "/") as NSString).expandingTildeInPath
        guard !name.contains(":"), !name.isEmpty else { return nil }
        let first = name.hasPrefix("/") ? URL(fileURLWithPath: name) : directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: first.path) { return first }
        guard !name.contains("/") else { return nil }
        if let farHome, FileManager.default.fileExists(atPath: farHome.appendingPathComponent(name).path) {
            return farHome.appendingPathComponent(name)
        }
        for root in Set(pluginRoots.values).sorted(by: { $0.path < $1.path }) {
            if let match = find(in: root, basename: name) { return match }
        }
        return nil
    }

    private func find(in root: URL, basename: String? = nil) -> URL? {
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var first: URL?
        let preferred = L10n.language == .russian ? "rus" : "eng"
        for entry in entries.prefix(4096) {
            guard let url = entry as? URL, url.pathExtension.lowercased() == "hlf",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if let basename {
                if url.lastPathComponent.caseInsensitiveCompare(basename) == .orderedSame { return url }
            } else {
                if url.deletingPathExtension().lastPathComponent.lowercased().hasSuffix(preferred) { return url }
                if first == nil { first = url }
            }
        }
        return first
    }

    private func hostHelp() throws -> HlfLocation {
        let names = L10n.language == .russian ? ["FarRus.hlf", "FarEng.hlf"] : ["FarEng.hlf", "FarRus.hlf"]
        for root in [farHome, Bundle.main.resourceURL].compactMap({ $0 }) {
            for name in names {
                let url = root.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) { return try HlfLocation(document: HlfLocation.load(url), url: url) }
            }
        }
        return try usage()
    }

    private func usage() throws -> HlfLocation {
        let text = """
        .Language=Russian,Русский
        .PluginContents=HlfViewer

        @Contents
        $ #HlfViewer#
         ~Командная строка~@cmd@
         ~Редактор~@editor@

        @cmd
        $ #Командная строка#
         #hlf:файл.hlf# [#тема#]
         #hlf:"файл с пробелами.hlf"# [#@@тема#]
         #hlf:GUID# [#тема#]

         ~Оглавление~@Contents@

        @editor
        $ #Редактор#
         F1 показывает текущую тему HLF при включённой обработке клавиш.
         В настройках можно выбрать сохранённую или редактируемую версию.

         ~Оглавление~@Contents@

        @Help
        $ #Клавиши справки#
         Tab и стрелка вправо переходят к следующей ссылке. Shift+Tab
        и стрелка влево возвращают к предыдущей ссылке. Enter открывает её.
         Backspace или Alt+F1 возвращает предыдущую тему.
         Shift+F1 открывает оглавление. F5 меняет полноэкранный режим.
         Esc и F10 закрывают окно.
        """
        return try HlfLocation(document: FarHelpDocument(text), url: nil)
    }
}

@MainActor
private final class HlfTextView: NSTextView {
    var onKey: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) { if onKey?(event) != true { super.keyDown(with: event) } }
}

@MainActor
private final class HlfViewerWindow: NSWindowController, NSTextViewDelegate {
    private struct Page {
        let location: HlfLocation
        let topic: String?
    }

    private let text = HlfTextView(frame: NSRect(x: 0, y: 0, width: 620, height: 480))
    private let status = NSTextField(labelWithString: "")
    private var history: [Page] = []
    private var position = 0
    private var links: [(FarHelpTarget, NSRange)] = []
    private var selectedLink: Int?
    private var scope = HlfSearchScope(directory: FileManager.default.homeDirectoryForCurrentUser)
    private var page: Page { history[position] }
    private(set) var currentTopic: String?
    var displayedText: String { text.string }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.center()
        text.isEditable = false; text.isSelectable = true
        text.importsGraphics = false; text.isRichText = true
        text.textContainerInset = NSSize(width: 16, height: 10)
        text.textContainer?.widthTracksTextView = true
        text.autoresizingMask = [.width]
        text.backgroundColor = Palette.background
        text.delegate = self
        text.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        let buttons = horizontal([
            NSButton(title: "Назад", target: self, action: #selector(goBack)),
            NSButton(title: "Вперёд", target: self, action: #selector(goForward)),
            NSButton(title: "Оглавление", target: self, action: #selector(contents)),
            NSButton(title: "Индекс", target: self, action: #selector(index))
        ])
        window.contentView = vertical([inset(buttons, x: 10, y: 8), scroll, inset(status, x: 10, y: 6)])
        window.initialFirstResponder = text
    }

    required init?(coder: NSCoder) { fatalError() }

    func open(_ location: HlfLocation, topic: String, scope: HlfSearchScope) {
        self.scope = scope
        history = [Page(location: location, topic: topic)]; position = 0
        render()
    }

    private func push(_ location: HlfLocation, topic: String?) {
        if position + 1 < history.count { history.removeLast(history.count - position - 1) }
        history.append(Page(location: location, topic: topic))
        if history.count > 16 { history.removeFirst() }
        position = history.count - 1
        render()
    }

    func follow(_ target: FarHelpTarget) {
        do {
            let (location, topic) = try scope.follow(target, from: page.location)
            push(location, topic: try location.document.topic(named: topic).name)
        } catch { status.stringValue = error.localizedDescription }
    }

    @objc func goBack() { if position > 0 { position -= 1; render() } }
    @objc private func goForward() { if position + 1 < history.count { position += 1; render() } }
    @objc private func contents() { follow(.topic("Contents")) }
    @objc private func index() { push(page.location, topic: nil) }

    private func render() {
        links.removeAll(); selectedLink = nil
        let document = page.location.document
        let title = document.title ?? page.location.url?.lastPathComponent ?? "HLF"
        currentTopic = page.topic
        window?.title = title + " — " + (page.topic ?? "Индекс")
        status.stringValue = page.location.url?.path ?? title
        let display = NSMutableAttributedString()
        if let name = page.topic, let topic = try? document.topic(named: name) {
            for paragraph in topic.paragraphs { append(paragraph, to: display) }
        } else {
            for topic in document.topics.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                appendLink(.topic(topic.name), label: topic.name, to: display)
                display.append(NSAttributedString(string: "\n"))
            }
        }
        text.textStorage?.setAttributedString(display)
        text.setSelectedRange(NSRange(location: 0, length: 0))
        text.scrollToBeginningOfDocument(nil)
    }

    private func append(_ paragraph: FarHelpParagraph, to display: NSMutableAttributedString) {
        let size = UIPreferences.fontSize(13)
        let regular = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 3
        if let indent = paragraph.hangingIndent {
            style.headIndent = CGFloat(indent) * ("M" as NSString).size(withAttributes: [.font: regular]).width
        }
        let heading: Bool
        switch paragraph.kind {
        case .heading(let centered): style.alignment = centered ? .center : .left; heading = true
        case .preformatted: style.paragraphSpacing = 0; heading = false
        case .rule(let character):
            display.append(NSAttributedString(string: String(repeating: String(character), count: 32) + "\n",
                                              attributes: [.font: regular, .foregroundColor: Palette.muted]))
            return
        default: heading = false
        }
        for run in paragraph.runs {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: heading || run.highlighted ? bold : regular,
                .foregroundColor: run.highlighted ? Palette.accent : Palette.text,
                .paragraphStyle: style
            ]
            if let color = run.consoleColor {
                attributes[.foregroundColor] = consoleColor(color & 15)
                attributes[.backgroundColor] = consoleColor(color >> 4)
            }
            if let link = run.link { appendLink(link, label: run.text, attributes: attributes, to: display) }
            else { display.append(NSAttributedString(string: run.text, attributes: attributes)) }
        }
        display.append(NSAttributedString(string: "\n", attributes: [.font: regular, .paragraphStyle: style]))
    }

    private func appendLink(_ target: FarHelpTarget, label: String, attributes: [NSAttributedString.Key: Any] = [:],
                            to display: NSMutableAttributedString) {
        let range = NSRange(location: display.length, length: label.utf16.count)
        var attributes = attributes
        let index: Int
        if let previous = links.last, previous.0 == target, NSMaxRange(previous.1) == range.location {
            index = links.count - 1
            links[index].1.length += range.length
        } else {
            index = links.count
            links.append((target, range))
        }
        attributes[.link] = NSNumber(value: index)
        attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        display.append(NSAttributedString(string: label, attributes: attributes))
    }

    private func consoleColor(_ nibble: UInt8) -> NSColor {
        let ansi = (nibble & 10) | ((nibble & 1) << 2) | ((nibble & 4) >> 2)
        let (r, g, b) = TerminalColor.indexed(ansi).rgbComponents
        return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let number = link as? NSNumber, links.indices.contains(number.intValue) { follow(links[number.intValue].0) }
        return true
    }

    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        switch (event.keyCode, flags) {
        case (53, []), (109, []): close()
        case (51, []), (122, .option):
            if position > 0 { goBack() } else { close() }
        case (96, []): window?.toggleFullScreen(nil)
        case (122, []): follow(.host("Help"))
        case (122, .shift): contents()
        case (48, []), (48, .shift), (123, []), (124, []):
            guard !links.isEmpty else { return false }
            let backwards = flags == .shift || event.keyCode == 123
            let selected = selectedLink ?? (backwards ? 0 : links.count - 1)
            let next = (selected + (backwards ? -1 : 1) + links.count) % links.count
            selectedLink = next
            text.setSelectedRange(links[next].1)
            text.scrollRangeToVisible(links[next].1)
        case (36, []), (76, []):
            guard let selectedLink, links.indices.contains(selectedLink) else { return false }
            follow(links[selectedLink].0)
        default: return false
        }
        return true
    }
}

extension HlfViewerWorkspace {
    static func runUISmokeChecks(in root: URL) throws -> [String] {
        let directory = root.appendingPathComponent("hlf-viewer-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let main = directory.appendingPathComponent("demo help.hlf")
        let child = directory.appendingPathComponent("extra.hlf")
        try ".Language=English\n@Contents\n$ #Original#\n~Jump~@<extra.hlf>Deep@".write(to: main, atomically: true, encoding: .utf8)
        try ".Language=English\n@Contents\nIndex\n@Deep\n$ #Child#\n~Missing~@Missing@".write(to: child, atomically: true, encoding: .utf8)
        let scope = HlfSearchScope(directory: directory)
        let (location, topic) = try scope.resolve(FarHelpInvocation(arguments: #""demo help.hlf" @Contents"#))
        let window = HlfViewerWindow()
        defer { window.close() }
        window.open(location, topic: try location.document.topic(named: topic).name, scope: scope)
        guard window.displayedText.contains("Original"), window.displayedText.contains("Jump") else {
            throw PanelSessionError("HLF native text did not render the heading and hyperlink label")
        }
        window.follow(.file("extra.hlf", topic: "Deep"))
        guard window.currentTopic == "Deep", window.displayedText.contains("Child") else {
            throw PanelSessionError("HLF viewer did not resolve a relative file from the current HLF")
        }
        window.follow(.topic("Missing"))
        guard window.currentTopic == "Deep", window.displayedText.contains("Child") else {
            throw PanelSessionError("HLF missing topic changed the visible help page")
        }
        window.goBack()
        guard window.currentTopic == "Contents", window.displayedText.contains("Original") else {
            throw PanelSessionError("HLF Back did not restore the previous document")
        }

        let workspace = HlfViewerWorkspace()
        let previous = AppPreferences.defaults.data(forKey: preferencesKey)
        defer { AppPreferences.defaults.set(previous, forKey: preferencesKey) }
        workspace.options = Options()
        let editor = try TextFileWindow(url: main)
        defer { editor.closeArchiveWorkingCopyWithoutSaving() }
        let position: FarLuaValue = .table(["CurLine": .integer(4), "CurPos": .integer(1)])
        guard try editor.luaEditorCall("editor.SetPosition", [.nilValue, position]) == [.bool(true)],
              try editor.luaEditorCall("editor.InsertText", [.nilValue, .string("@OnlyInEditor\n")]) == [.bool(true)],
              editor.extensionText.contains("\n@Contents\n"), editor.extensionText.contains("\n@OnlyInEditor\n"),
              FarEditorCoordinates(editor.extensionText).position(editor.extensionSelection.location).line == 5 else {
            throw PanelSessionError("HLF fixture could not add and enter a new topic in the unsaved editor buffer")
        }
        guard case .failed(let error) = workspace.openEditorTopic(editor),
              error.localizedDescription == FarHelpError.missingTopic("OnlyInEditor").localizedDescription else {
            throw PanelSessionError("HLF did not report that the unsaved editor topic is absent in the saved document")
        }
        guard !workspace.showCurrentTopic(editor) else {
            throw PanelSessionError("HLF Lua call must return false when the editor topic is absent in the saved document")
        }
        guard workspace.executePrefix("hlf", #""demo help.hlf" @Missing"#, directory: directory),
              workspace.lastFailure == FarHelpError.missingTopic("Missing").localizedDescription else {
            throw PanelSessionError("HLF must handle the prefix and expose the missing-topic error to CommandX")
        }
        workspace.clearFailure()
        guard workspace.lastFailure == nil else { throw PanelSessionError("HLF command failure leaked into the next command") }
        return ["HlfViewer renders native help text, follows relative topic links and preserves a page on error",
                "HlfViewer returns failure to Lua and exposes a handled prefix error to the command runner"]
    }
}
