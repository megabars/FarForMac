import AppKit
import FarCore

enum AuxiliaryPanelMode: String { case tree, info, quickView }

private final class InspectionTextView: NSTextView {
    var onFocus: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    override func becomeFirstResponder() -> Bool { onFocus?(); return super.becomeFirstResponder() }
    override func mouseDown(with event: NSEvent) { onFocus?(); super.mouseDown(with: event) }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}

private final class InspectionOutline: NSOutlineView {
    var onFocus: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    override func becomeFirstResponder() -> Bool { onFocus?(); return super.becomeFirstResponder() }
    override func mouseDown(with event: NSEvent) { onFocus?(); super.mouseDown(with: event) }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}

/// Embeddable body of a panel. The host keeps its path, file cursor and marks;
/// every update invalidates old worker results before rendering new content.
@MainActor
final class AuxiliaryPanelView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onFocus: (() -> Void)?
    var onNavigate: ((URL) -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    private(set) var mode: AuxiliaryPanelMode = .info
    private let heading = label("", size: 12, color: Palette.accent, bold: true)
    private let status = label("", size: 11, color: Palette.muted)
    private let cancelButton = NSButton(title: "Отменить", target: nil, action: nil)
    private let scroll = NSScrollView()
    private let text = InspectionTextView()
    private let outline = InspectionOutline()
    private var generation = 0
    private var cancellation = FileToolCancellation()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var root: TreeNode?
    private var showHidden = false
    private var lastUpdate: UpdateIdentity?

    private struct UpdateIdentity: Equatable {
        let mode: AuxiliaryPanelMode
        let directory: String
        let selected: String?
        let size: Int64?
        let modified: Date?
        let showHidden: Bool
    }

    private final class TreeNode {
        let url: URL
        let isSymbolicLink: Bool
        var children: [TreeNode]?
        var loading = false
        var expandWhenLoaded = false
        var error: String?
        init(url: URL, isSymbolicLink: Bool = false) { self.url = url; self.isSymbolicLink = isSymbolicLink }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; layer?.backgroundColor = Palette.panel.cgColor
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textColor = Palette.text; text.backgroundColor = Palette.panel
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.setAccessibilityLabel("Информация и быстрый просмотр")
        text.onFocus = { [weak self] in self?.onFocus?() }
        text.onKey = { [weak self] event in self?.onKey?(event) ?? false }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("directory"))
        column.title = "Каталоги"; column.width = 400
        outline.addTableColumn(column); outline.outlineTableColumn = column
        outline.headerView = nil; outline.backgroundColor = Palette.panel
        outline.rowHeight = 25; outline.indentationPerLevel = 16
        outline.dataSource = self; outline.delegate = self
        outline.target = self; outline.doubleAction = #selector(openTreeSelection)
        outline.allowsMultipleSelection = false
        outline.setAccessibilityLabel("Дерево каталогов")
        outline.onFocus = { [weak self] in self?.onFocus?() }
        outline.onKey = { [weak self] event in
            guard let self else { return false }
            if self.onKey?(event) == true { return true }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard modifiers.isEmpty else { return false }
            if event.keyCode == 36 || event.keyCode == 76 { self.openTreeSelection(); return true }
            if event.keyCode == 51, let root = self.root, root.url.path != "/" {
                self.onNavigate?(root.url.deletingLastPathComponent()); return true
            }
            return false
        }
        cancelButton.target = self; cancelButton.action = #selector(cancelReading)
        cancelButton.bezelStyle = .inline; cancelButton.isHidden = true
        let footer = horizontal([status, cancelButton])
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for view in [heading, scroll, footer] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            heading.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 9),
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
        scroll.documentView = text
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        cancellation.cancel()
        for task in tasks.values { task.cancel() }
    }

    func update(mode: AuxiliaryPanelMode, directory: URL, selected: FileEntry?, showHidden: Bool = false) {
        let identity = UpdateIdentity(mode: mode, directory: directory.standardizedFileURL.path,
                                      selected: mode == .tree ? nil : selected?.id,
                                      size: mode == .tree ? nil : selected?.size,
                                      modified: mode == .tree ? nil : selected?.modified, showHidden: showHidden)
        guard identity != lastUpdate else { return }
        cancel()
        lastUpdate = identity
        self.mode = mode; self.showHidden = showHidden
        cancellation = FileToolCancellation()
        status.stringValue = "Чтение…"; cancelButton.isHidden = false
        root = nil; outline.reloadData()
        let target = selected?.url ?? directory
        heading.stringValue = "\(mode == .tree ? "ДЕРЕВО" : mode == .info ? "ИНФОРМАЦИЯ" : "БЫСТРЫЙ ПРОСМОТР")  ·  \(mode == .tree ? directory.path : target.lastPathComponent)"
        if mode == .tree {
            scroll.documentView = outline
            let node = TreeNode(url: directory.resolvingSymlinksInPath())
            root = node; outline.reloadData()
            loadChildren(node, expand: true)
            return
        }
        scroll.documentView = text
        text.frame = NSRect(origin: .zero, size: scroll.contentSize)
        text.string = "Чтение \(target.path)…"
        let token = cancellation, current = generation, identifier = UUID()
        let requestedMode = mode
        tasks[identifier] = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<(String, String), Error> in
                Result {
                    if requestedMode == .info {
                        let info = try PanelInspection.information(directory: directory, selected: selected?.url, cancellation: token)
                        return (Self.informationText(info), "Метаданные прочитаны · только чтение")
                    }
                    let info = try PanelInspection.information(directory: directory, selected: selected?.url, cancellation: token)
                    if info.item.linkDestination != nil {
                        return (Self.informationText(info), "Ссылка показана без обхода её цели")
                    }
                    if info.item.kind == "Папка" {
                        let size = try PanelInspection.directorySize(target, cancellation: token)
                        return (Self.sizeText(size, path: target.path), size.isPartial ? "Неполный результат" : "Подсчёт завершён · логический размер")
                    }
                    let preview = try PanelInspection.preview(target, cancellation: token)
                    let mode = preview.isBinary ? "HEX" : preview.encoding.title
                    let amount = preview.isTruncated ? "Показано \(preview.displayedBytes) из \(preview.totalBytes) байт · F3 в файловой панели — полный просмотр" : "\(preview.totalBytes) байт"
                    return (preview.text.isEmpty ? "Пустой файл" : preview.text, "\(mode) · \(amount)")
                }
            }.value
            guard let self, self.generation == current, !token.isCancelled else { return }
            self.tasks.removeValue(forKey: identifier)
            self.cancelButton.isHidden = true
            switch result {
            case .success(let value): self.text.string = value.0; self.status.stringValue = value.1
            case .failure(let error): self.text.string = error.localizedDescription; self.status.stringValue = "Не удалось прочитать объект"
            }
            self.text.scrollToBeginningOfDocument(nil)
        }
    }

    func focus() { window?.makeFirstResponder(mode == .tree ? outline : text) }

    func cancel() {
        generation += 1
        lastUpdate = nil
        cancellation.cancel()
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        cancelButton.isHidden = true
    }

    @objc private func cancelReading() {
        cancel(); status.stringValue = "Чтение отменено"
        if mode != .tree { text.string = "Чтение отменено. Повторно выберите режим для обновления." }
        focus()
    }

    private func loadChildren(_ node: TreeNode, expand: Bool = false) {
        if expand { node.expandWhenLoaded = true }
        guard node.children == nil, !node.loading, !node.isSymbolicLink, !cancellation.isCancelled else { return }
        node.loading = true
        let token = cancellation, current = generation, hidden = showHidden, identifier = UUID(), url = node.url
        cancelButton.isHidden = false
        tasks[identifier] = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try PanelInspection.treeChildren(url, showHidden: hidden, cancellation: token) }
            }.value
            guard let self, self.generation == current, !token.isCancelled else { return }
            self.tasks.removeValue(forKey: identifier)
            node.loading = false
            switch result {
            case .success(let listing):
                node.children = listing.entries.map { TreeNode(url: $0.url, isSymbolicLink: $0.isSymbolicLink) }
                self.status.stringValue = "Enter — перейти · ←/→ — ветви · Backspace — выше"
                if listing.truncated { self.status.stringValue = "Показаны первые \(listing.entries.count) папок; список ограничен" }
                if listing.unreadable > 0 { self.status.stringValue += " · Недоступны: \(listing.unreadable)" }
            case .failure(let error):
                node.children = []; node.error = error.localizedDescription
                self.status.stringValue = error.localizedDescription
            }
            self.outline.reloadItem(node, reloadChildren: true)
            if node.expandWhenLoaded || self.outline.isItemExpanded(node) { self.outline.expandItem(node) }
            if self.outline.selectedRow < 0, self.outline.numberOfRows > 0 {
                self.outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
            self.cancelButton.isHidden = self.tasks.isEmpty
        }
    }

    @objc private func openTreeSelection() {
        guard let node = outline.item(atRow: outline.selectedRow) as? TreeNode else { return }
        onNavigate?(node.url.resolvingSymlinksInPath())
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? TreeNode else { return root == nil ? 0 : 1 }
        if node.children == nil { loadChildren(node) }
        return node.children?.count ?? 0
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? TreeNode { return node.children![index] }
        return root!
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? TreeNode else { return false }
        return !node.isSymbolicLink && (node.children == nil || !node.children!.isEmpty)
    }
    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? TreeNode else { return }
        node.expandWhenLoaded = true
        loadChildren(node)
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        (notification.userInfo?["NSObject"] as? TreeNode)?.expandWhenLoaded = false
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? TreeNode else { return nil }
        let field = label((node === root ? node.url.path : node.url.lastPathComponent) + (node.isSymbolicLink ? " ↗" : ""), color: node.isSymbolicLink ? Palette.muted : Palette.text)
        field.toolTip = node.error ?? (node.isSymbolicLink ? "Ссылка: Enter — перейти; вложенные ветви не обходятся" : node.url.path)
        return field
    }

    nonisolated private static func bytes(_ value: Int64?) -> String {
        guard let value else { return "Недоступно" }
        return "\(ByteCountFormatter.string(fromByteCount: value, countStyle: .file)) (\(value) байт)"
    }
    nonisolated private static func informationText(_ info: PanelInformation) -> String {
        let item = info.item
        var lines = ["Каталог: \(info.directory.path)", "Том: \(info.volumeName ?? "—")",
                     "Всего: \(bytes(info.totalBytes))", "Свободно: \(bytes(info.freeBytes))", "",
                     "Объект: \(item.url.path)", "Тип: \(item.kind)", "Размер объекта: \(bytes(item.bytes))",
                     "Права: \(item.permissions)", "Владелец: \(item.owner)",
                     "Изменён: \(item.modified.formatted(date: .numeric, time: .standard))"]
        if let destination = item.linkDestination { lines.append("Цель ссылки: \(destination)") }
        return lines.joined(separator: "\n")
    }
    nonisolated private static func sizeText(_ size: PanelDirectorySize, path: String) -> String {
        ["Папка: \(path)", "", "Логический размер: \(bytes(size.bytes))", "Файлы: \(size.files)",
         "Вложенные папки: \(size.directories)", "Символические ссылки: \(size.symbolicLinks)",
         "Недоступны / глубина свыше \(PanelInspection.maximumDirectoryDepth): \(size.unreadable)", "",
         "Ссылки не обходятся. Скрытые файлы учитываются.", "Жёсткие ссылки учитываются по каждой записи.",
         size.isPartial ? "Результат неполный." : "Подсчёт завершён."].joined(separator: "\n")
    }
}
