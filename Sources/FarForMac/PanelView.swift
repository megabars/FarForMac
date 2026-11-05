import AppKit
import FarCore

@MainActor
enum Palette {
    static var background: NSColor { UIPreferences.color(NSColor(calibratedRed: 0.035, green: 0.065, blue: 0.13, alpha: 1), contrast: .black) }
    static var panel: NSColor { UIPreferences.color(NSColor(calibratedRed: 0.055, green: 0.095, blue: 0.18, alpha: 1), contrast: .black) }
    static var raised: NSColor { UIPreferences.color(NSColor(calibratedRed: 0.085, green: 0.14, blue: 0.24, alpha: 1), contrast: NSColor(calibratedWhite: 0.12, alpha: 1)) }
    static var accent: NSColor { UIPreferences.color(NSColor(calibratedRed: 0.32, green: 0.88, blue: 0.78, alpha: 1), contrast: .yellow) }
    static var text: NSColor { UIPreferences.color(NSColor(calibratedRed: 0.88, green: 0.92, blue: 0.98, alpha: 1), contrast: .white) }
    static var muted: NSColor { UIPreferences.color(NSColor(calibratedRed: 0.53, green: 0.63, blue: 0.77, alpha: 1), contrast: NSColor(calibratedWhite: 0.85, alpha: 1)) }
}

@MainActor func label(_ value: String, size: CGFloat = 12, color: NSColor? = nil, bold: Bool = false) -> NSTextField {
    let field = NSTextField(labelWithString: value)
    field.font = .monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
    field.textColor = color ?? Palette.text
    field.lineBreakMode = .byTruncatingMiddle
    return field
}

@MainActor func vertical(_ views: [NSView], spacing: CGFloat = 0) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = spacing
    for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    return stack
}

@MainActor func horizontal(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = spacing
    return stack
}

@MainActor func inset(_ content: NSView, x: CGFloat = 14, y: CGFloat = 10, color: NSColor? = nil) -> NSView {
    let wrapper = NSView()
    if let color { wrapper.wantsLayer = true; wrapper.layer?.backgroundColor = color.cgColor }
    content.translatesAutoresizingMaskIntoConstraints = false
    wrapper.addSubview(content)
    NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: x),
        content.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -x),
        content.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: y),
        content.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -y)
    ])
    return wrapper
}

final class FileTable: NSTableView, NSMenuItemValidation {
    var onFocus: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    var onMouse: ((NSEvent) -> Bool)?
    var onShiftRelease: (() -> Void)?
    var onSelectAll: (() -> Void)?
    override func selectAll(_ sender: Any?) { onSelectAll?() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Panel marks are independent of NSTableView's single cursor selection.
        // AppKit's default Select All validation would disable this action.
        if menuItem.action == #selector(selectAll(_:)) { return onSelectAll != nil }
        return true
    }
    override func becomeFirstResponder() -> Bool { onFocus?(); return super.becomeFirstResponder() }
    override func mouseDown(with event: NSEvent) {
        onFocus?()
        if onMouse?(event) == true { return }
        super.mouseDown(with: event)
    }
    override func flagsChanged(with event: NSEvent) {
        if !event.modifierFlags.contains(.shift) { onShiftRelease?() }
        super.flagsChanged(with: event)
    }
    override func resignFirstResponder() -> Bool {
        onShiftRelease?()
        return super.resignFirstResponder()
    }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
}

final class FileRow: NSTableRowView {
    var active = false
    override func drawSelection(in dirtyRect: NSRect) {
        (active ? Palette.accent.withAlphaComponent(0.21) : Palette.raised).setFill()
        bounds.fill()
        if active {
            Palette.accent.setFill()
            NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
        }
    }
}

enum PanelDisplayMode: String, Codable, CaseIterable { case brief, full, custom }

@MainActor
final class PanelView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let table = FileTable()
    private let fileScroll = NSScrollView()
    private let archiveContainer = NSView()
    enum ResourceKind { case localNetwork, connections, processes }
    private(set) var resourceKind: ResourceKind?
    private(set) var resourceView: NSView?
    private var resourceFocus: (() -> Void)?
    private var resourceRefresh: (() -> Void)?
    private var resourceStop: (() -> Void)?
    private var resourceActivate: ((Bool) -> Void)?
    var resourceParent: (() -> Void)?
    var resourceFunction: ((Int, Bool) -> Bool)?
    var isResource: Bool { resourceView != nil }
    var onChooseResource: ((PanelView, NSView) -> Void)?
    var onRemoteReturn: ((PanelView) -> Void)?
    let resourceButton = NSButton(title: "Диск ▾", target: nil, action: nil)

    private(set) var archivePanel: ArchivePanelView?
    private(set) var archiveFrame: ArchiveNavigationFrame?
    var onRemoteDisconnect: ((any RemoteProvider) -> Void)?
    private var archiveNavigationStates: [ObjectIdentifier: ArchivePanelView.NavigationState] = [:]
    private(set) var virtualPanel: VirtualResultsPanelView?
    private var virtualDirectoryState: (filter: String, quickFind: String, quickFindHidden: Bool, sort: FileSortOptions)?
    var isVirtual: Bool { virtualPanel != nil }
    var virtualResults: [SearchMatch] { virtualPanel?.results ?? [] }
    var selectedVirtualResults: [SearchMatch] { virtualPanel?.selectedResults ?? [] }
    var cursorVirtualResult: SearchMatch? { virtualPanel?.cursorResult }
    var onVirtualResultsChange: (([SearchMatch]) -> Void)?
    private(set) var virtualLibrarySlot: Int?
    var onVirtualLibrarySnapshot: ((Int, [SearchMatch]) -> Void)?
    private var synchronizingVirtualLibrary = false
    var onVirtualReveal: ((PanelView, SearchMatch) -> Void)?
    var onVirtualDelete: ((PanelView) -> Void)?
    var onVirtualOpen: ((PanelView, SearchMatch) -> Void)?
    private(set) var remotePanel: RemotePanelView?
    var isRemote: Bool { remotePanel != nil }
    var locationGeneration: Int { generation }
    var onRemoteRefresh: ((PanelView) -> Void)?
    var isArchive: Bool { archivePanel != nil }
    var onArchiveView: ((PanelView, String) -> Void)?
    var onArchiveOpenNested: ((PanelView, String) -> Void)?
    var onArchiveRefresh: ((PanelView) -> Void)?
    var onArchiveSwitchPanel: (() -> Void)?

    private let auxiliary = AuxiliaryPanelView()
    private let modePicker = NSPopUpButton()
    private var auxiliaryColumnLayout: (widths: [String: CGFloat], autosave: Bool)?
    private var columnLayoutGeneration = 0
    private var restoringColumnLayout = true
    private(set) var contentMode: PanelContentMode = .files
    var onSelectionChange: ((PanelView) -> Void)?
    var onContentModeChange: ((PanelView) -> Void)?
    private var pendingSession: PanelSession?
    private var restoringSession = false
    private var descriptions: [String: String] = [:]
    private var descriptionNotice = ""
    private var sortGroupNotice = ""
    var sortGroups = SortGroups() { didSet { resortKeepingCursor() } }


    let pathField = NSTextField()
    let filterField = NSSearchField()
    let quickFindField = NSSearchField()
    let title = label("", size: 11, bold: true)
    let summary = label("", size: 11, color: Palette.muted)
    let locationKey: String
    private(set) var directory: URL
    private(set) var entries: [FileEntry] = []
    private(set) var visible: [FileEntry] = []
    private(set) var loading = false
    var showHidden = false
    private(set) var sortOptions = FileSortOptions()
    var sort: FileSort {
        get { sortOptions.sort }
        set { var options = sortOptions; options.sort = newValue; setSortOptions(options) }
    }
    var ascending: Bool {
        get { sortOptions.ascending }
        set { var options = sortOptions; options.ascending = newValue; setSortOptions(options) }
    }
    private(set) var displayMode: PanelDisplayMode = .custom
    private(set) var visibleColumnIDs: Set<String> = ["name", "size", "modified"]
    private(set) var customColumnIDs: Set<String> = ["name", "size", "modified"]
    private(set) var colorizeFiles = true
    var maskGroups: [String: String] = [:]
    var onDirectoryChange: ((PanelView) -> Void)?
    private(set) var recordDirectoryActivity = true
    private var navigation: PanelNavigation
    private enum HistoryAction: Equatable { case visit, back, forward, restore }
    private struct DirectorySnapshot {
        let entries: [FileEntry]
        let selection: PanelSelection
        let cursorRow: Int
        let columnWidths: [String: CGFloat]
        let columnOrder: [String]
        let filter: String
        let quickFind: String
        let quickFindHidden: Bool
        let sortOptions: FileSortOptions
        let displayMode: PanelDisplayMode
        let customColumnIDs: Set<String>
        let colorizeFiles: Bool
    }
    private var directorySnapshot: DirectorySnapshot?
    private var searchResults: [String: SearchResult] = [:]
    private var removedResultCount = 0
    private var metadataTask: Task<([FileEntry], [String]), Never>?
    private let returnButton = NSButton(title: "Вернуться к папке", target: nil, action: nil)
    var isTemporary: Bool { directorySnapshot != nil }
    private(set) var temporaryLibrarySlot: Int?
    var onTemporaryLibrarySnapshot: ((Int, [SearchResult]) -> Void)?
    var temporaryTitle: String? {
        if isVirtual { return L10n.text("Временная панель") + (virtualLibrarySlot.map { " · \($0)" } ?? "") }
        guard isTemporary else { return nil }
        return "Временная панель" + (temporaryLibrarySlot.map { " · \($0)" } ?? "")
    }
    var historyPaths: [String] { navigation.history }
    var canGoBack: Bool { isVirtual || isTemporary || navigation.backPath != nil }
    var canGoForward: Bool { !isVirtual && navigation.forwardPath != nil }
    var onFocus: ((PanelView) -> Void)?
    var onError: ((Error) -> Void)?
    var onFileOpen: ((FileEntry) -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    var active = false { didSet { updateActive() } }
    private var generation = 0
    private var selection = PanelSelection()
    private var shiftMarking: Bool?
    private var synchronizingTable = false
    private var hasParent = false
    private var offset: Int { hasParent ? 1 : 0 }

    init(directory: URL, key: String) {
        self.directory = directory
        self.locationKey = key
        let defaults = AppPreferences.defaults
        if let data = defaults.data(forKey: "panel.\(key).history"),
           let saved = try? JSONDecoder().decode(PanelNavigation.self, from: data) {
            self.navigation = saved
        } else { self.navigation = PanelNavigation(path: directory.path) }
        super.init(frame: .zero)
        if let data = defaults.data(forKey: "panel.\(key).session"),
           let saved = try? PanelSession.decode(data), saved.directory == directory.path { pendingSession = saved }

        if let data = defaults.data(forKey: "panel.\(key).sort"),
           let saved = try? JSONDecoder().decode(FileSortOptions.self, from: data) { sortOptions = saved }
        displayMode = PanelDisplayMode(rawValue: defaults.string(forKey: "panel.\(key).display") ?? "custom") ?? .custom
        if let columns = defaults.stringArray(forKey: "panel.\(key).columns") { customColumnIDs = Set(columns).intersection(Set(Self.columnDefinitions.map(\.id))).union(["name"]) }
        if defaults.object(forKey: "panel.\(key).colorize") != nil { colorizeFiles = defaults.bool(forKey: "panel.\(key).colorize") }
        wantsLayer = true
        layer?.backgroundColor = Palette.panel.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        pathField.stringValue = directory.path
        pathField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        pathField.textColor = Palette.text
        pathField.backgroundColor = Palette.background
        pathField.isBezeled = false
        pathField.focusRingType = .none
        pathField.target = self
        pathField.action = #selector(goToPath)
        pathField.setAccessibilityLabel("Путь \(key == "left" ? "левой" : "правой") панели")
        let up = NSButton(image: NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "На уровень выше")!, target: self, action: #selector(parent))
        up.bezelStyle = .texturedRounded
        let path = horizontal([up, pathField])
        pathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        filterField.placeholderString = "Фильтр в этой папке  ⌘F"
        filterField.font = .systemFont(ofSize: 12)
        filterField.delegate = self
        filterField.sendsSearchStringImmediately = true
        filterField.setAccessibilityLabel("Фильтр \(key == "left" ? "левой" : "правой") панели")

        quickFindField.placeholderString = "Быстрый поиск  ⌥буква · ⌃↩ далее · Esc закрыть"
        quickFindField.font = .systemFont(ofSize: 12)
        quickFindField.delegate = self
        quickFindField.sendsSearchStringImmediately = true
        quickFindField.setAccessibilityLabel("Быстрый поиск")
        quickFindField.isHidden = true

        table.backgroundColor = Palette.panel
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = []
        table.rowHeight = 29
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelection)
        table.setAccessibilityLabel(key == "left" ? "Левая файловая панель" : "Правая файловая панель")
        for definition in Self.columnDefinitions {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(definition.id))
            column.title = definition.title
            column.width = definition.width
            column.maxWidth = 4096
            column.minWidth = definition.id == "name" ? 120 : (definition.id == "origin" ? 180 : 55)
            column.resizingMask = definition.id == "name" ? .autoresizingMask : .userResizingMask
            column.headerCell.font = .systemFont(ofSize: 11, weight: .medium)
            table.addTableColumn(column)
        }
        if !AppRuntime.isSmoke { table.autosaveName = "FarMac.\(key).columns" }
        table.autosaveTableColumns = !AppRuntime.isSmoke
        updateColumns()
        restorePersistedColumnLayout()
        restoringColumnLayout = false
        let scroll = fileScroll
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        returnButton.target = self
        returnButton.action = #selector(returnToDirectory)
        returnButton.bezelStyle = .rounded
        returnButton.isHidden = true
        modePicker.addItems(withTitles: PanelContentMode.allCases.map(\.title))
        modePicker.target = self; modePicker.action = #selector(modeChanged)
        modePicker.setAccessibilityLabel("Режим \(key == "left" ? "левой" : "правой") панели")
        auxiliary.isHidden = true
        auxiliary.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        auxiliary.onFocus = { [weak self] in guard let self else { return }; self.onFocus?(self) }
        auxiliary.onNavigate = { [weak self] url in self?.load(url, preserveSelection: false) }
        auxiliary.onKey = { [weak self] event in
            guard let self else { return false }
            if event.keyCode == 53 { self.setContentMode(.files); self.focus(); return true }
            if event.keyCode == 48 { return self.onKey?(event) ?? false }
            return false
        }
        resourceButton.target = self; resourceButton.action = #selector(chooseResource)
        resourceButton.bezelStyle = .recessed
        resourceButton.setAccessibilityLabel("Выбор диска и ресурса \(key == "left" ? "левой" : "правой") панели")
        resourceButton.toolTip = key == "left" ? "Сменить диск — Alt+F1" : "Сменить диск — Alt+F2"
        let header = inset(vertical([horizontal([resourceButton, title, modePicker]), returnButton, path, filterField, quickFindField], spacing: 10), color: Palette.raised)
        archiveContainer.isHidden = true
        archiveContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        let body = vertical([header, scroll, auxiliary, archiveContainer, inset(summary, y: 9)])
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: leadingAnchor), body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.topAnchor.constraint(equalTo: topAnchor), body.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        table.onFocus = { [weak self] in guard let self else { return }; self.onFocus?(self) }
        table.onKey = { [weak self] event in
            guard let self else { return false }
            return self.handleQuickFindKey(event) || self.handleSelectionKey(event) || (self.onKey?(event) ?? false)
        }
        table.onMouse = { [weak self] event in self?.handleSelectionMouse(event) ?? false }
        table.onShiftRelease = { [weak self] in self?.shiftMarking = nil }
        table.onSelectAll = { [weak self] in self?.markAll() }
        updateActive()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load(_ url: URL? = nil, preserveSelection: Bool = true, selectName: String? = nil) {
        if isVirtual {
            guard url != nil else { return }
            leaveVirtualResults(focus: false)
        }
        if isRemote { if url == nil { onRemoteRefresh?(self); return }; leaveRemote(focus: false) }
        if isArchive {
            if url == nil { onArchiveRefresh?(self); return }
            leaveArchive(focus: false)
        }
        if isTemporary, url == nil { refresh(); return }
        load(url, preserveSelection: preserveSelection, selectName: selectName, historyAction: .visit)
    }

    /// Ordinary search results begin an independent collection, without a common-slot link.
    func showVirtualResults(_ results: [SearchMatch], focusPanel: Bool = true) throws {
        try showVirtualResults(results, linkedSlot: nil, focusPanel: focusPanel)
    }
    func showVirtualLibrarySlot(_ slot: Int, matches: [SearchMatch], focusPanel: Bool = true) throws {
        guard (0..<PersistentTemporaryPanels.slotCount).contains(slot) else { throw PanelSessionError(L10n.text("Номер общей панели должен быть от 0 до 9.")) }
        try showVirtualResults(matches, linkedSlot: slot, focusPanel: focusPanel)
    }
    /// A store reload is authoritative. Suppress write-back while replacing both linked views.
    func refreshVirtualLibrarySlot(_ slot: Int, references: [SavedSearchReference]) throws {
        guard virtualLibrarySlot == slot, let virtualPanel else { return }
        synchronizingVirtualLibrary = true
        defer { synchronizingVirtualLibrary = false }
        let existing = Dictionary(virtualPanel.results.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let replacements = references.map { reference -> SearchMatch in
            if let live = existing[reference.id], case .saved = live { return .saved(reference) }
            if let live = existing[reference.id], (try? SavedSearchReference(capturing: live)) == reference { return live }
            return .saved(reference)
        }
        try virtualPanel.replaceReferences(replacements)
    }
    /// Upgrade only the exact descriptors that were restored; unrelated or changed
    /// rows remain offline. The collection keeps cursor, marks and slot affiliation.
    func applyRestoredVirtualMatches(_ matches: [SearchMatch]) throws {
        guard let virtualPanel else { return }
        let restored = Dictionary(matches.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let replacements = virtualPanel.results.map { current -> SearchMatch in
            guard case .saved(let reference) = current, let live = restored[current.id],
                  (try? SavedSearchReference(capturing: live)) == reference else { return current }
            return live
        }
        try virtualPanel.replaceReferences(replacements)
    }
    private func notifyVirtualResultsChange(_ results: [SearchMatch]) {
        guard !synchronizingVirtualLibrary else { return }
        onVirtualResultsChange?(results)
        if let slot = virtualLibrarySlot { onVirtualLibrarySnapshot?(slot, results) }
    }
    private func showVirtualResults(_ results: [SearchMatch], linkedSlot: Int?, focusPanel: Bool) throws {
        // Validate before changing the existing slot affiliation.
        guard Set(results.map(\.id)).count <= TemporarySearchCollection.maximumCount else { throw PanelSessionError(L10n.text("Во временной панели допускается не более 10 000 ссылок.")) }
        virtualLibrarySlot = linkedSlot
        if let virtualPanel {
            generation += 1
            try virtualPanel.replaceReferences(results)
            updateActive()
            if focusPanel { focus() }
            return
        }
        let browser = try VirtualResultsPanelView(results: results)
        if isRemote { leaveRemote(focus: false) }
        if isArchive { leaveArchive(focus: false) }
        if isTemporary { _ = restoreDirectorySnapshot() }
        setContentMode(.files)
        columnLayoutGeneration += 1
        if auxiliaryColumnLayout == nil {
            auxiliaryColumnLayout = (Dictionary(uniqueKeysWithValues: table.tableColumns.map { ($0.identifier.rawValue, $0.width) }), table.autosaveTableColumns)
        }
        table.autosaveTableColumns = false; table.columnAutoresizingStyle = .noColumnAutoresizing
        virtualDirectoryState = (filterField.stringValue, quickFindField.stringValue, quickFindField.isHidden, sortOptions)
        endQuickFind(focusTable: false); metadataTask?.cancel(); metadataTask = nil
        generation += 1; loading = false
        virtualPanel = browser; browser.setSortOptions(sortOptions); browser.setActive(active)
        browser.onFocus = { [weak self] in guard let self else { return }; self.onFocus?(self) }
        browser.onClose = { [weak self] in self?.leaveVirtualResults() }
        browser.onSwitchPanel = { [weak self] in self?.onArchiveSwitchPanel?() }
        browser.onReveal = { [weak self] result in guard let self else { return }; self.onVirtualReveal?(self, result) }
        browser.onDelete = { [weak self] in guard let self else { return }; self.onVirtualDelete?(self) }
        browser.onAction = { [weak self] event in guard let self else { return false }; return self.handleQuickFindKey(event) || (self.onKey?(event) ?? false) }
        browser.onChange = { [weak self] in guard let self else { return }; self.onSelectionChange?(self) }
        browser.onResultsChange = { [weak self] in self?.notifyVirtualResultsChange($0) }
        browser.translatesAutoresizingMaskIntoConstraints = false; archiveContainer.addSubview(browser)
        NSLayoutConstraint.activate([browser.leadingAnchor.constraint(equalTo: archiveContainer.leadingAnchor), browser.trailingAnchor.constraint(equalTo: archiveContainer.trailingAnchor), browser.topAnchor.constraint(equalTo: archiveContainer.topAnchor), browser.bottomAnchor.constraint(equalTo: archiveContainer.bottomAnchor)])
        fileScroll.isHidden = true; auxiliary.isHidden = true; archiveContainer.isHidden = false
        filterField.stringValue = ""; filterField.placeholderString = "Фильтр результатов  ⌘F"; filterField.isHidden = false
        quickFindField.isHidden = true; modePicker.isHidden = true
        returnButton.isHidden = false; returnButton.title = "Вернуться к папке"
        pathField.isEditable = false; pathField.stringValue = L10n.text("Временные результаты поиска · локальные файлы / архивы / сеть")
        updateActive(); updateSummary(); onSelectionChange?(self)
        notifyVirtualResultsChange(browser.results)
        if focusPanel { focus() }
    }
    func appendVirtualResults(_ results: [SearchMatch]) throws {
        if let virtualPanel { try virtualPanel.append(results) }
        else { try showVirtualResults(results) }
    }
    func removeVirtualSelection() { virtualPanel?.removeSelection() }
    func leaveVirtualResults(focus: Bool = true) {
        guard let browser = virtualPanel else { return }
        generation += 1; virtualLibrarySlot = nil
        browser.removeFromSuperview(); browser.releaseReferences(); virtualPanel = nil; archiveContainer.isHidden = true
        fileScroll.isHidden = false; filterField.isHidden = false; modePicker.isHidden = false
        filterField.stringValue = virtualDirectoryState?.filter ?? ""; filterField.placeholderString = "Фильтр в этой папке  ⌘F"
        pathField.isEditable = true; pathField.stringValue = directory.path
        returnButton.isHidden = true
        quickFindField.stringValue = virtualDirectoryState?.quickFind ?? ""
        quickFindField.isHidden = virtualDirectoryState?.quickFindHidden ?? true
        if let options = virtualDirectoryState?.sort { sortOptions = options }
        virtualDirectoryState = nil
        setContentMode(.files); updateActive(); updateSummary(); onSelectionChange?(self)
        if focus { self.focus() }
    }

    @objc private func chooseResource() { onChooseResource?(self, resourceButton) }
    func closeRemote() {
        leaveRemote(focus: false)
        if let onRemoteReturn { onRemoteReturn(self) } else { focus() }
    }
    func showResource(_ view: NSView, kind: ResourceKind, caption: String,
                      focus: @escaping () -> Void, refresh: @escaping () -> Void,
                      stop: @escaping () -> Void, setActive: @escaping (Bool) -> Void,
                      perform: @escaping (Int, Bool) -> Bool) {
        leaveResource(focus: false)
        if isVirtual { leaveVirtualResults(focus: false) }
        if isRemote { leaveRemote(focus: false) }
        if isArchive { leaveArchive(focus: false) }
        setContentMode(.files)
        endQuickFind(focusTable: false); metadataTask?.cancel(); generation += 1; loading = false
        resourceView = view; resourceKind = kind; resourceFocus = focus; resourceRefresh = refresh
        resourceStop = stop; resourceActivate = setActive; resourceFunction = perform
        view.translatesAutoresizingMaskIntoConstraints = false; archiveContainer.addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: archiveContainer.leadingAnchor), view.trailingAnchor.constraint(equalTo: archiveContainer.trailingAnchor), view.topAnchor.constraint(equalTo: archiveContainer.topAnchor), view.bottomAnchor.constraint(equalTo: archiveContainer.bottomAnchor)])
        fileScroll.isHidden = true; auxiliary.isHidden = true; archiveContainer.isHidden = false
        filterField.isHidden = true; quickFindField.isHidden = true; modePicker.isHidden = true
        returnButton.isHidden = false; returnButton.title = "Вернуться к папке"
        pathField.isEditable = false; pathField.stringValue = caption; summary.stringValue = caption
        updateActive(); onSelectionChange?(self); focus()
    }
    func updateResourceCaption(_ caption: String) {
        guard isResource else { return }; pathField.stringValue = caption
    }
    func leaveResource(focus: Bool = true) {
        guard let view = resourceView else { return }
        resourceStop?(); view.removeFromSuperview()
        resourceParent = nil; resourceView = nil; resourceKind = nil; resourceFunction = nil; resourceFocus = nil
        resourceRefresh = nil; resourceStop = nil; resourceActivate = nil; generation += 1
        archiveContainer.isHidden = true; fileScroll.isHidden = false; modePicker.isHidden = false
        filterField.isHidden = false; pathField.isEditable = true; pathField.stringValue = directory.path
        returnButton.isHidden = !isTemporary; updateActive(); updateSummary(); onSelectionChange?(self)
        if focus { self.focus() }
    }

    func showRemote(_ browser: RemotePanelView) {
        if isResource { leaveResource(focus: false) }
        if isVirtual { leaveVirtualResults(focus: false) }
        if isArchive { leaveArchive(focus: false) }
        if let previous = remotePanel {
            leaveRemote(focus: false, notifyDisconnect: previous.provider !== browser.provider)
        }
        setContentMode(.files)
        columnLayoutGeneration += 1
        if auxiliaryColumnLayout == nil { auxiliaryColumnLayout = (Dictionary(uniqueKeysWithValues: table.tableColumns.map { ($0.identifier.rawValue, $0.width) }), table.autosaveTableColumns) }
        table.autosaveTableColumns = false; table.columnAutoresizingStyle = .noColumnAutoresizing
        endQuickFind(focusTable: false); metadataTask?.cancel(); generation += 1; loading = false
        remotePanel = browser; browser.setActive(active)
        browser.onFocus = { [weak self] in guard let self else { return }; self.onFocus?(self) }
        browser.onClose = { [weak self] in self?.closeRemote() }
        browser.onSwitchPanel = { [weak self] in self?.onArchiveSwitchPanel?() }
        browser.onChange = { [weak self] in self?.updateRemoteCaption() }
        browser.translatesAutoresizingMaskIntoConstraints = false; archiveContainer.addSubview(browser)
        NSLayoutConstraint.activate([browser.leadingAnchor.constraint(equalTo: archiveContainer.leadingAnchor), browser.trailingAnchor.constraint(equalTo: archiveContainer.trailingAnchor), browser.topAnchor.constraint(equalTo: archiveContainer.topAnchor), browser.bottomAnchor.constraint(equalTo: archiveContainer.bottomAnchor)])
        fileScroll.isHidden = true; auxiliary.isHidden = true; archiveContainer.isHidden = false
        filterField.isHidden = true; quickFindField.isHidden = true; modePicker.isHidden = true
        returnButton.isHidden = false; returnButton.title = "Отключиться"
        pathField.isEditable = false; updateRemoteCaption(); focus()
    }
    func leaveRemote(focus: Bool = true, notifyDisconnect: Bool = true) {
        guard let browser = remotePanel else { return }
        generation += 1
        browser.removeFromSuperview(); remotePanel = nil; archiveContainer.isHidden = true
        if notifyDisconnect { onRemoteDisconnect?(browser.provider) }
        fileScroll.isHidden = false; filterField.isHidden = false; modePicker.isHidden = false
        pathField.isEditable = true; pathField.stringValue = directory.path
        returnButton.title = "Вернуться к папке"; returnButton.isHidden = !isTemporary
        setContentMode(.files); updateActive(); updateSummary(); onSelectionChange?(self)
        if focus { self.focus() }
    }
    static func runNetworkLifecycleUISmokeChecks() throws -> [String] {
        guard AppRuntime.isSmoke, let base = AppRuntime.smokeStateDirectory else { throw NetworkError.io("Missing smoke state") }
        let panel = PanelView(directory: base, key: "network-lifecycle-" + UUID().uuidString)
        let first = ProviderUISmokeFixture(), second = ProviderUISmokeFixture()
        var disconnected: [ObjectIdentifier] = []
        panel.onRemoteDisconnect = { disconnected.append(ObjectIdentifier($0)) }
        panel.showRemote(RemotePanelView(provider: first, path: "/", entries: []))
        panel.showRemote(RemotePanelView(provider: first, path: "/docs", entries: []))
        guard disconnected.isEmpty else { throw NetworkError.io("Same-provider reveal closed SSH") }
        panel.showRemote(RemotePanelView(provider: second, path: "/", entries: []))
        guard disconnected == [ObjectIdentifier(first)] else { throw NetworkError.io("Provider replacement did not disconnect old session") }
        let connectedGeneration = panel.locationGeneration
        panel.leaveRemote(focus: false); panel.leaveRemote(focus: false); panel.cancelInspection()
        guard disconnected == [ObjectIdentifier(first), ObjectIdentifier(second)], panel.locationGeneration == connectedGeneration + 1 else { throw NetworkError.io("Panel exit must disconnect exactly once and invalidate pending previews") }
        return ["Replacing a remote browser with the same provider preserves connection", "Provider replacement and panel exit disconnect the previous provider exactly once"]
    }
    private func updateRemoteCaption() {
        guard let remotePanel else { return }
        pathField.stringValue = remotePanel.caption
        summary.stringValue = "Сеть · F3 просмотр · F4 рабочая копия · F5 копировать · F8 удалить без Корзины"
        updateActive(); onSelectionChange?(self)
    }
    func showArchive(_ snapshot: ArchiveSnapshot) {
        showArchive(frame: ArchiveNavigationFrame(snapshot: snapshot))
    }
    func showArchive(frame: ArchiveNavigationFrame) {
        if isResource { leaveResource(focus: false) }
        if isVirtual { leaveVirtualResults(focus: false) }
        let snapshot = frame.snapshot
        if isRemote { leaveRemote(focus: false) }
        if let archivePanel {
            var restoredState: ArchivePanelView.NavigationState?
            if let previous = archiveFrame, previous !== frame {
                if frame.parent === previous {
                    archiveNavigationStates[ObjectIdentifier(previous)] = archivePanel.captureNavigationState()
                } else if previous.parent === frame {
                    restoredState = archiveNavigationStates.removeValue(forKey: ObjectIdentifier(frame))
                } else { archiveNavigationStates.removeAll() }
            }
            archiveFrame = frame
            archivePanel.frameDisplayPath = frame.displayPath
            archivePanel.update(snapshot: snapshot)
            if let restoredState { archivePanel.restoreNavigationState(restoredState) }
            updateArchiveCaption(); return
        }
        setContentMode(.files)
        columnLayoutGeneration += 1
        if auxiliaryColumnLayout == nil {
            auxiliaryColumnLayout = (Dictionary(uniqueKeysWithValues: table.tableColumns.map { ($0.identifier.rawValue, $0.width) }), table.autosaveTableColumns)
        }
        table.autosaveTableColumns = false; table.columnAutoresizingStyle = .noColumnAutoresizing
        endQuickFind(focusTable: false)
        metadataTask?.cancel(); generation += 1; loading = false
        let browser = ArchivePanelView(snapshot: snapshot)
        archiveFrame = frame
        browser.frameDisplayPath = frame.displayPath
        archivePanel = browser
        browser.onFocus = { [weak self] in guard let self else { return }; self.onFocus?(self) }
        browser.onClose = { [weak self] in self?.closeArchiveLevel() }
        browser.onSwitchPanel = { [weak self] in self?.onArchiveSwitchPanel?() }
        browser.onView = { [weak self] path in guard let self else { return }; self.onArchiveView?(self, path) }
        browser.onOpenArchive = { [weak self] path in guard let self else { return }; self.onArchiveOpenNested?(self, path) }
        browser.onDirectoryChange = { [weak self] in self?.updateArchiveCaption() }
        browser.setActive(active)
        browser.translatesAutoresizingMaskIntoConstraints = false; archiveContainer.addSubview(browser)
        NSLayoutConstraint.activate([browser.leadingAnchor.constraint(equalTo: archiveContainer.leadingAnchor), browser.trailingAnchor.constraint(equalTo: archiveContainer.trailingAnchor), browser.topAnchor.constraint(equalTo: archiveContainer.topAnchor), browser.bottomAnchor.constraint(equalTo: archiveContainer.bottomAnchor)])
        fileScroll.isHidden = true; auxiliary.isHidden = true; archiveContainer.isHidden = false
        filterField.isHidden = true; quickFindField.isHidden = true; modePicker.isHidden = true
        returnButton.isHidden = false; returnButton.title = "Закрыть архив"
        pathField.isEditable = false
        updateArchiveCaption(); focus()
    }
    func closeArchiveLevel() {
        guard let frame = archiveFrame, let parent = frame.parent else { leaveArchive(); return }
        // Returning is also possible after an external change: the saved parent
        // remains readable as a listing, while all operations verify its snapshot.
        let hasSavedState = archiveNavigationStates[ObjectIdentifier(parent)] != nil
        showArchive(frame: parent)
        if !hasSavedState, let path = frame.memberPath { archivePanel?.reveal(path: path) }
        focus()
    }
    func leaveArchive(focus: Bool = true) {
        guard let browser = archivePanel else { return }
        browser.removeFromSuperview(); archivePanel = nil; archiveFrame = nil; archiveContainer.isHidden = true
        archiveNavigationStates.removeAll()
        fileScroll.isHidden = false; filterField.isHidden = false; modePicker.isHidden = false
        pathField.isEditable = true; pathField.stringValue = directory.path
        returnButton.title = "Вернуться к папке"; returnButton.isHidden = !isTemporary
        setContentMode(.files)
        updateActive(); updateSummary(); onSelectionChange?(self)
        if focus { self.focus() }
    }
    private func updateArchiveCaption() {
        guard let archivePanel else { return }
        pathField.stringValue = (archiveFrame?.displayPath ?? archivePanel.snapshot.sourceURL.path) + " !/" + archivePanel.currentDirectory
        returnButton.title = archiveFrame?.parent == nil ? L10n.text("Закрыть архив") : L10n.text("К родительскому архиву")
        summary.stringValue = archivePanel.snapshot.isReadOnly
            ? L10n.text("Архив только для чтения · F3 просмотр · F5 извлечь")
            : "Архив · F3 просмотр · F4 рабочая копия · F5 извлечь · F8 удалить из архива"
        updateActive(); onSelectionChange?(self)
    }
    @objc private func modeChanged() {
        let index = modePicker.indexOfSelectedItem
        guard PanelContentMode.allCases.indices.contains(index) else { return }
        setContentMode(PanelContentMode.allCases[index]); focus()
    }
    func setContentMode(_ mode: PanelContentMode) {
        if isResource { leaveResource(focus: false) }
        if isVirtual { leaveVirtualResults(focus: false) }
        if isRemote { leaveRemote(focus: false) }
        if isArchive { leaveArchive(focus: false) }
        columnLayoutGeneration += 1
        let layoutGeneration = columnLayoutGeneration
        if contentMode == .files && mode != .files && auxiliaryColumnLayout == nil {
            auxiliaryColumnLayout = (
                Dictionary(uniqueKeysWithValues: table.tableColumns.map { ($0.identifier.rawValue, $0.width) }),
                table.autosaveTableColumns
            )
        }
        if auxiliaryColumnLayout != nil {
            // A hidden arranged scroll view can acquire an intermediate viewport
            // width. Keep that layout pass from resizing and saving the name column.
            table.autosaveTableColumns = false
            table.columnAutoresizingStyle = .noColumnAutoresizing
        }
        contentMode = mode
        modePicker.selectItem(at: PanelContentMode.allCases.firstIndex(of: mode) ?? 0)
        fileScroll.isHidden = mode != .files; auxiliary.isHidden = mode == .files
        filterField.isHidden = mode != .files
        if mode != .files { endQuickFind(focusTable: false) }
        auxiliary.cancel()
        updateActive()
        onContentModeChange?(self)
        if mode == .files, let saved = auxiliaryColumnLayout {
            restoreColumnWidths(saved.widths)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.contentMode == .files, !self.isArchive, !self.isRemote, !self.isVirtual,
                      self.columnLayoutGeneration == layoutGeneration else { return }
                self.window?.contentView?.layoutSubtreeIfNeeded()
                self.updateColumnAutoresizing()
                self.restoreColumnWidths(saved.widths)
                self.table.autosaveTableColumns = !self.isTemporary && saved.autosave
                self.auxiliaryColumnLayout = nil
            }
        }
    }
    static func runColumnLayoutUISmokeChecks() async throws -> [String] {
        guard AppRuntime.isSmoke, let root = AppRuntime.smokeStateDirectory else { throw PanelSessionError("Column layout smoke needs isolated defaults") }
        let folder = root.appendingPathComponent("column-layout-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("one.txt"); try Data("one".utf8).write(to: file)
        let key = "layout-smoke-" + UUID().uuidString
        let panel = PanelView(directory: folder, key: key)
        let firstWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        firstWindow.isReleasedWhenClosed = false; firstWindow.contentView = panel; firstWindow.orderFront(nil)
        firstWindow.contentView?.layoutSubtreeIfNeeded()
        defer { firstWindow.close() }
        panel.load()
        let deadline = Date().addingTimeInterval(5)
        while panel.loading && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        guard !panel.loading, let size = panel.table.tableColumns.first(where: { $0.identifier.rawValue == "size" }),
              let index = panel.table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "size" }) else { throw PanelSessionError("Column fixture did not load") }
        size.width = 198; panel.table.moveColumn(index, toColumn: 0); panel.persistSession()
        guard let originalData = AppPreferences.defaults.data(forKey: panel.columnLayoutKey) else { throw PanelSessionError("Column geometry not persisted") }
        let saved = try PanelColumnLayout.decode(originalData)
        let recreated = PanelView(directory: folder, key: key)
        let secondWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        secondWindow.isReleasedWhenClosed = false; secondWindow.contentView = recreated; secondWindow.orderFront(nil)
        secondWindow.contentView?.layoutSubtreeIfNeeded()
        defer { secondWindow.close() }
        try await Task.sleep(nanoseconds: 30_000_000)
        guard recreated.table.tableColumns.first?.identifier.rawValue == "size",
              recreated.table.tableColumns.first(where: { $0.identifier.rawValue == "size" })?.width == 198 else {
            throw PanelSessionError("Recreated panel lost dragged order/resized width")
        }
        panel.showSearchResults([try SearchResult.capture(file)])
        panel.table.tableColumns.first(where: { $0.identifier.rawValue == "origin" })?.width = 413
        panel.persistSession()
        guard let transientData = AppPreferences.defaults.data(forKey: panel.columnLayoutKey),
              try PanelColumnLayout.decode(transientData) == saved else { throw PanelSessionError("Temporary origin column contaminated folder layout") }
        _ = panel.restoreDirectorySnapshot()
        panel.persistSession()
        guard let restoredData = AppPreferences.defaults.data(forKey: panel.columnLayoutKey),
              try PanelColumnLayout.decode(restoredData) == saved else { throw PanelSessionError("Returning from temporary panel changed saved geometry") }
        AppPreferences.defaults.set(Data("invalid".utf8), forKey: panel.columnLayoutKey)
        let recovered = PanelView(directory: folder, key: key)
        guard recovered.table.tableColumns.contains(where: { $0.identifier.rawValue == "name" }) else { throw PanelSessionError("Invalid geometry broke panel construction") }
        panel.cancelInspection(); recreated.cancelInspection(); recovered.cancelInspection()
        return ["Column width and order survive panel reconstruction and real window layout using isolated preferences",
                "Temporary panel origin layout does not overwrite saved folder columns",
                "Invalid saved column layout falls back to available columns"]
    }

    private var columnLayoutKey: String { "panel.\(locationKey).columnLayout.v1" }
    func tableViewColumnDidMove(_ notification: Notification) {
        if auxiliaryColumnLayout == nil && !isTemporary && !isArchive && !isRemote && !isVirtual && !isResource { updateColumnAutoresizing() }
        persistColumnLayout()
    }
    private func updateColumnAutoresizing() {
        // AppKit's first-column policy follows the physical column index. After
        // a drag it must not stretch a user's explicitly sized metadata column.
        table.columnAutoresizingStyle = table.tableColumns.first?.identifier.rawValue == "name" ? .firstColumnOnlyAutoresizingStyle : .noColumnAutoresizing
    }
    func tableViewColumnDidResize(_ notification: Notification) { persistColumnLayout() }
    private func persistColumnLayout() {
        guard !restoringColumnLayout, !isTemporary, !isArchive, !isRemote, !isVirtual, !isResource,
              contentMode == .files, auxiliaryColumnLayout == nil else { return }
        let columns = table.tableColumns
        guard let layout = try? PanelColumnLayout(order: columns.map { $0.identifier.rawValue },
            widths: Dictionary(uniqueKeysWithValues: columns.map { ($0.identifier.rawValue, Double($0.width)) })),
              let data = try? layout.encoded() else { return }
        AppPreferences.defaults.set(data, forKey: columnLayoutKey)
    }
    private func restorePersistedColumnLayout() {
        guard let data = AppPreferences.defaults.data(forKey: columnLayoutKey),
              let layout = try? PanelColumnLayout.decode(data) else { return }
        let wasRestoring = restoringColumnLayout; restoringColumnLayout = true
        defer { restoringColumnLayout = wasRestoring }
        for (position, id) in layout.orderedColumns(available: table.tableColumns.map { $0.identifier.rawValue }).enumerated() {
            if let current = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == id }), current != position {
                table.moveColumn(current, toColumn: position)
            }
        }
        updateColumnAutoresizing()
        for column in table.tableColumns {
            if let width = layout.widths[column.identifier.rawValue] { column.width = max(column.minWidth, CGFloat(width)) }
        }
    }

    private func restoreColumnWidths(_ widths: [String: CGFloat]) {
        for column in table.tableColumns {
            if let width = widths[column.identifier.rawValue] { column.width = width }
        }
        table.tile()
    }
    func updateAuxiliary(directory source: URL, selected: FileEntry?) {
        guard contentMode != .files, let mode = AuxiliaryPanelMode(rawValue: contentMode.rawValue) else { return }
        auxiliary.update(mode: mode, directory: contentMode == .tree ? directory : source,
                         selected: selected, showHidden: showHidden)
    }
    func applyInterfacePreferences() {
        table.backgroundColor = Palette.panel
        pathField.textColor = Palette.text
        table.setAccessibilityLabel(UIAccessibility.panelName(locationKey))
        pathField.setAccessibilityLabel(UIAccessibility.panelName(locationKey) + ", " + L10n.text("Путь"))
        filterField.setAccessibilityLabel(UIAccessibility.panelName(locationKey) + ", " + L10n.text("Фильтр"))
        quickFindField.setAccessibilityLabel(L10n.text("Быстрый поиск"))
        updateColumnTitles()
        table.reloadData()
    }
    func invalidateUnavailableVolume(_ volume: URL) {
        guard !isArchive, !isRemote, !isTemporary, !isVirtual, !isResource else { return }
        let path = directory.standardizedFileURL.path, root = volume.standardizedFileURL.path
        guard path == root || path.hasPrefix(root + "/") else { return }
        generation += 1; loading = false; cancelInspection()
        entries = []; descriptions = [:]
        applyFilter(resetSelection: true)
        summary.stringValue = L10n.language == .english ? "Folder unavailable. Refresh when the volume returns." : "Папка недоступна. Обновите после подключения тома."
    }
    func cancelInspection() { auxiliary.cancel() }
    func persistSession() {
        guard !isVirtual, !isResource else { return }
        persistColumnLayout()
        guard !loading else { return }
        let saved = PanelSession(directory: directory.path, mode: contentMode,
                                 cursorID: selection.cursorID, filter: filterField.stringValue,
                                 temporaryItems: isTemporary ? Array(searchResults.values) : nil,
                                 directoryCursorID: directorySnapshot?.selection.cursorID,
                                 directoryFilter: directorySnapshot?.filter ?? "")
        do { AppPreferences.defaults.set(try saved.encoded(), forKey: "panel.\(locationKey).session") }
        catch { onError?(error) }
    }
    private func restorePendingSession() {
        guard let saved = pendingSession else { return }
        pendingSession = nil; restoringSession = true
        defer { restoringSession = false }
        if let items = saved.temporaryItems {
            filterField.stringValue = saved.directoryFilter; applyFilter()
            if let id = saved.directoryCursorID, let row = visible.firstIndex(where: { $0.id == id }) { moveCursor(to: row + offset) }
            showSearchResults(items)
        }
        filterField.stringValue = saved.filter; applyFilter()
        if let id = saved.cursorID, let row = visible.firstIndex(where: { $0.id == id }) { moveCursor(to: row + offset) }
        setContentMode(saved.mode)
        if active { focus() }
    }
    func addTemporaryItems(_ additions: [SearchResult]) throws {
        let slot = temporaryLibrarySlot
        let merged = try TemporaryPanelItems.merging(isTemporary ? Array(searchResults.values) : [], additions)
        showSearchResults(merged)
        temporaryLibrarySlot = slot
        if let slot { onTemporaryLibrarySnapshot?(slot, temporaryResults); updateActive() }
    }
    func removeTemporarySelection() {
        guard isTemporary, !loading else { return }
        let ids = Set(selection.operationIDs(orderedIDs: visible.map(\.id)))
        for id in ids { searchResults.removeValue(forKey: id) }
        entries.removeAll { ids.contains($0.id) }; applyFilter()
        if let slot = temporaryLibrarySlot { onTemporaryLibrarySnapshot?(slot, temporaryResults) }
    }
    func markPaths(_ urls: [URL]) {
        guard !isArchive && !isRemote && !isVirtual && !isResource, contentMode == .files, !loading else { return }
        selection.saveMarks(); selection.clearMarks()
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        selection.setMarked(visible.filter { paths.contains($0.url.standardizedFileURL.path) }.map(\.id), marked: true)
        reloadMarks()
    }

    /// Results are a distinct, in-memory panel source; the directory and its history stay intact.
    func showTemporaryLibrarySlot(_ slot: Int, items: [SearchResult], focus: Bool = true) {
        guard (0..<TemporaryPanelLibrary.slotCount).contains(slot) else { return }
        showSearchResults(items, focusPanel: focus)
        temporaryLibrarySlot = slot; updateActive()
    }
    func showSearchResults(_ results: [SearchResult], focusPanel: Bool = true) {
        if isVirtual { leaveVirtualResults(focus: false) }
        if let slot = temporaryLibrarySlot { onTemporaryLibrarySnapshot?(slot, temporaryResults) }
        temporaryLibrarySlot = nil
        if isRemote { leaveRemote(focus: false) }
        if isArchive { leaveArchive(focus: false) }
        setContentMode(.files)
        metadataTask?.cancel()
        generation += 1
        loading = false
        if !isTemporary {
            directorySnapshot = DirectorySnapshot(
                entries: entries, selection: selection, cursorRow: table.selectedRow,
                columnWidths: Dictionary(uniqueKeysWithValues: table.tableColumns.map { ($0.identifier.rawValue, $0.width) }),
                columnOrder: table.tableColumns.map { $0.identifier.rawValue },
                filter: filterField.stringValue,
                quickFind: quickFindField.stringValue, quickFindHidden: quickFindField.isHidden,
                sortOptions: sortOptions, displayMode: displayMode,
                customColumnIDs: customColumnIDs, colorizeFiles: colorizeFiles
            )
        }
        searchResults = Dictionary(results.map { ($0.url.path, $0) }, uniquingKeysWith: { first, _ in first })
        removedResultCount = 0
        selection = PanelSelection()
        filterField.stringValue = ""
        filterField.placeholderString = "Фильтр результатов  ⌘F"
        endQuickFind(focusTable: false)
        entries = FileService.sorted(searchResults.values.map {
            FileEntry(url: $0.url, name: $0.name, isDirectory: $0.isDirectory,
                      isSymbolicLink: $0.isSymbolicLink, size: $0.size, modified: $0.modified)
        }, options: sortOptions)
        returnButton.isHidden = false
        // A forced origin column must not overwrite the saved directory layout.
        table.autosaveTableColumns = false
        if let originIndex = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "origin" }) {
            table.moveColumn(originIndex, toColumn: 1)
        }
        updateColumns()
        updateActive()
        applyFilter(resetSelection: true)
        refresh()
        if !restoringSession && focusPanel { focus() }
    }

    func leaveSearchResults() {
        guard restoreDirectorySnapshot() else { return }
        load(nil, preserveSelection: true, historyAction: .restore)
        focus()
    }

    @objc private func returnToDirectory() { if isResource { leaveResource() } else if isVirtual { leaveVirtualResults() } else if isRemote { closeRemote() } else if isArchive { closeArchiveLevel() } else { leaveSearchResults() } }

    @discardableResult
    private func restoreDirectorySnapshot() -> Bool {
        guard let snapshot = directorySnapshot else { return false }
        let wasRestoringColumns = restoringColumnLayout; restoringColumnLayout = true
        defer { restoringColumnLayout = wasRestoringColumns; persistColumnLayout() }
        if let slot = temporaryLibrarySlot { onTemporaryLibrarySnapshot?(slot, temporaryResults) }
        temporaryLibrarySlot = nil
        metadataTask?.cancel()
        metadataTask = nil
        generation += 1
        loading = false
        directorySnapshot = nil
        searchResults.removeAll()
        removedResultCount = 0
        entries = snapshot.entries
        selection = snapshot.selection
        filterField.stringValue = snapshot.filter
        filterField.placeholderString = "Фильтр в этой папке  ⌘F"
        quickFindField.stringValue = snapshot.quickFind
        quickFindField.isHidden = snapshot.quickFindHidden
        sortOptions = snapshot.sortOptions
        displayMode = snapshot.displayMode
        customColumnIDs = snapshot.customColumnIDs
        colorizeFiles = snapshot.colorizeFiles
        pathField.stringValue = directory.path
        returnButton.isHidden = true
        for (index, id) in snapshot.columnOrder.enumerated() {
            if let current = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == id }) {
                table.moveColumn(current, toColumn: index)
            }
        }
        updateColumns()
        for column in table.tableColumns {
            if let width = snapshot.columnWidths[column.identifier.rawValue] { column.width = width }
        }
        table.autosaveTableColumns = !AppRuntime.isSmoke
        updateActive()
        applyFilter()
        if snapshot.cursorRow >= 0 { moveCursor(to: snapshot.cursorRow) }
        return true
    }

    func refresh() {
        if isResource { resourceRefresh?(); return }
        if isVirtual { return }
        if isRemote { onRemoteRefresh?(self); return }; if isArchive { onArchiveRefresh?(self); return }
        guard isTemporary else { load(); return }
        metadataTask?.cancel()
        generation += 1
        let token = generation
        let results = Array(searchResults.values)
        loading = true
        summary.stringValue = "Обновление результатов…"
        let worker = Task.detached(priority: .userInitiated) {
            var current: [FileEntry] = []
            var invalidIDs: [String] = []
            for result in results {
                guard !Task.isCancelled else { break }
                do { current.append(try Self.refreshResult(result)) }
                catch { invalidIDs.append(result.url.path) }
            }
            return (current, invalidIDs)
        }
        metadataTask = worker
        Task {
            let refreshed = await worker.value
            guard token == generation, isTemporary else { return }
            metadataTask = nil
            for id in refreshed.1 { searchResults.removeValue(forKey: id) }
            removedResultCount += refreshed.1.count
            entries = sortedEntries(refreshed.0)
            loading = false
            applyFilter()
            if let slot = temporaryLibrarySlot { onTemporaryLibrarySnapshot?(slot, temporaryResults) }
        }
    }

    /// Keep the captured identity: refreshing metadata must never accept a replacement at the same path.
    nonisolated private static func refreshResult(_ result: SearchResult) throws -> FileEntry {
        try result.verifyCurrent()
        let manager = FileManager.default
        let attributes = try manager.attributesOfItem(atPath: result.url.path)
        let isLink = attributes[.type] as? FileAttributeType == .typeSymbolicLink
        let target = isLink ? (try? manager.attributesOfItem(atPath: result.url.resolvingSymlinksInPath().path)) : nil
        let display = target ?? attributes
        let dates = try? result.url.resourceValues(forKeys: [.creationDateKey, .contentAccessDateKey])
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        var permissions = isLink ? "l" : (display[.type] as? FileAttributeType == .typeDirectory ? "d" : "-")
        for (read, write, execute, special, lower, upper) in [
            (0o400, 0o200, 0o100, 0o4000, "s", "S"),
            (0o040, 0o020, 0o010, 0o2000, "s", "S"),
            (0o004, 0o002, 0o001, 0o1000, "t", "T")
        ] {
            permissions += mode & read != 0 ? "r" : "-"
            permissions += mode & write != 0 ? "w" : "-"
            permissions += mode & special != 0 ? (mode & execute != 0 ? lower : upper) : (mode & execute != 0 ? "x" : "-")
        }
        try result.verifyCurrent()
        return FileEntry(
            url: result.url, name: result.name,
            isDirectory: display[.type] as? FileAttributeType == .typeDirectory,
            isSymbolicLink: isLink, size: (display[.size] as? NSNumber)?.int64Value ?? 0,
            modified: display[.modificationDate] as? Date,
            created: dates?.creationDate ?? display[.creationDate] as? Date,
            accessed: dates?.contentAccessDate, permissions: permissions,
            owner: attributes[.ownerAccountName] as? String ?? ""
        )
    }

    private func load(_ url: URL?, preserveSelection: Bool, selectName: String? = nil, historyAction: HistoryAction, recordActivity: Bool = true) {
        guard !isVirtual, !isResource else { return }
        restoreDirectorySnapshot()
        let target = (url ?? directory).standardizedFileURL
        generation += 1
        let token = generation
        loading = true
        summary.stringValue = "Чтение папки…"
        let hidden = showHidden
        let options = sortOptions, groups = sortGroups, masks = maskGroups, marks = selection.markedIDs
        let descriptionEncoding = DescriptionPreferences.encoding(for: target)
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let raw = try FileService.list(target, showHidden: hidden, sortResult: false)
                    let sorted = Self.sortedSnapshot(raw, options: options, marks: marks, groups: groups, masks: masks)
                    do { return (sorted.0, try FileDescriptions.load(directory: target, encoding: descriptionEncoding).descriptions, "", sorted.1) }
                    catch { return (sorted.0, [String: String](), "Описания: " + error.localizedDescription, sorted.1) }
                }.value
                guard token == generation else { return }
                let resetSelection = target != directory || !preserveSelection
                if target != directory {
                    filterField.stringValue = ""
                    endQuickFind(focusTable: false)
                }
                switch historyAction {
                case .visit: navigation.visit(target.path)
                case .back: navigation.commitBack()
                case .forward: navigation.commitForward()
                case .restore: break
                }
                if historyAction != .restore { persistNavigation() }
                directory = target
                if sortOptions == options && sortGroups == groups && maskGroups == masks && selection.markedIDs == marks {
                    entries = result.0; sortGroupNotice = result.3
                } else {
                    // A user changed the ordering while I/O ran; preserve their latest choice.
                    entries = sortedEntries(result.0)
                }
                descriptions = result.1; descriptionNotice = result.2
                pathField.stringValue = target.path
                AppPreferences.defaults.set(target.path, forKey: "panel.\(locationKey)")
                loading = false
                applyFilter(resetSelection: resetSelection, selectName: selectName)
                restorePendingSession()
                recordDirectoryActivity = recordActivity
                onDirectoryChange?(self)
                recordDirectoryActivity = true
            } catch {
                guard token == generation else { return }
                loading = false
                pathField.stringValue = directory.path
                summary.stringValue = "Не удалось прочитать папку"
                onError?(error)
            }
        }
    }

    var cursorEntry: FileEntry? {
        guard !isArchive && !isRemote && !isVirtual && !isResource, contentMode == .files, !loading, let entry = entry(at: table.selectedRow), validateResults([entry]) else { return nil }
        return entry
    }
    var selectedEntries: [FileEntry] {
        guard !isArchive && !isRemote && !isVirtual && !isResource, contentMode == .files, !loading else { return [] }
        let ids = Set(selection.operationIDs(orderedIDs: visible.map(\.id)))
        let selected = visible.filter { ids.contains($0.id) }
        // Reject the entire requested batch if any source is stale; never fall back to the cursor.
        return validateResults(selected) ? selected : []
    }
    var markedEntries: [FileEntry] {
        guard !isArchive && !isRemote && !isVirtual && !isResource, contentMode == .files, !loading else { return [] }
        let marked = visible.filter { selection.markedIDs.contains($0.id) }
        return validateResults(marked) ? marked : []
    }

    /// Carry the original snapshots across dialogs so submission can recheck the same sources.
    var temporaryResults: [SearchResult] { isTemporary ? entries.compactMap { searchResults[$0.id] } : [] }

    func capturedSearchResults(for entries: [FileEntry]) -> [SearchResult] {
        guard isTemporary else { return [] }
        return entries.compactMap { searchResults[$0.id] }
    }

    private func validateResults(_ candidates: [FileEntry]) -> Bool {
        guard isTemporary else { return true }
        var invalid = Set<String>()
        var firstError: Error?
        for entry in candidates {
            do {
                guard let result = searchResults[entry.id] else {
                    throw NSError(domain: "FarMac.Search", code: 1, userInfo: [NSLocalizedDescriptionKey: "Результат поиска больше недоступен: «\(entry.url.path)»."])
                }
                try result.verifyCurrent()
            } catch { invalid.insert(entry.id); if firstError == nil { firstError = error } }
        }
        guard !invalid.isEmpty else { return true }
        metadataTask?.cancel()
        metadataTask = nil
        generation += 1
        loading = false
        for id in invalid { searchResults.removeValue(forKey: id) }
        removedResultCount += invalid.count
        entries.removeAll { invalid.contains($0.id) }
        applyFilter()
        if let firstError { onError?(firstError) }
        return false
    }

    func saveSelectionForOperation() { if let virtualPanel { virtualPanel.saveSelectionForOperation(); return }; selection.saveMarks(); shiftMarking = nil }

    func toggleMarkAndAdvance() {
        if let virtualPanel { virtualPanel.toggleMarkAndAdvance(); return }
        guard !loading else { return }
        shiftMarking = nil
        selection.saveMarks()
        if let entry = cursorEntry { selection.toggle(entry.id) }
        moveCursor(to: table.selectedRow + 1)
        reloadMarks()
    }
    func markAll() {
        if let virtualPanel { virtualPanel.markAll(); return }
        guard !loading else { return }
        selection.saveMarks()
        shiftMarking = nil
        selection.setMarked(visible.map(\.id), marked: true)
        reloadMarks()
    }
    /// Clearing after an operation keeps its pre-operation snapshot available to Ctrl+M.
    func clearMarks() {
        if let virtualPanel { virtualPanel.clearMarks(); return }
        shiftMarking = nil
        selection.clearMarks()
        reloadMarks()
    }
    func restoreMarks() {
        if let virtualPanel { virtualPanel.restoreMarks(); return }
        guard !loading else { return }
        shiftMarking = nil
        selection.restoreMarks(validIDs: visible.map(\.id))
        reloadMarks()
    }
    func invertMarks(includeDirectories: Bool = false) {
        if let virtualPanel { virtualPanel.invertMarks(includeDirectories: includeDirectories); return }
        guard !loading else { return }
        selection.saveMarks()
        shiftMarking = nil
        // Default FAR inversion also removes previously marked directories.
        let ids = visible.filter { includeDirectories || !$0.isDirectory || selection.markedIDs.contains($0.id) }.map(\.id)
        selection.invert(ids)
        reloadMarks()
    }
    func invertFilesAndClearDirectories() { invertMarks() }
    func selectSameExtension(mark: Bool) {
        if let virtualPanel { virtualPanel.selectSameName(mark: mark, byExtension: true); return }
        guard let current = cursorEntry, !loading else { return }
        let ext = current.url.pathExtension
        let ids = visible.filter {
            (!mark || !$0.isDirectory) && $0.url.pathExtension.caseInsensitiveCompare(ext) == .orderedSame
        }.map(\.id)
        selection.saveMarks()
        shiftMarking = nil
        selection.setMarked(ids, marked: mark)
        reloadMarks()
    }
    func selectSameName(mark: Bool) {
        if let virtualPanel { virtualPanel.selectSameName(mark: mark, byExtension: false); return }
        guard let current = cursorEntry, !loading else { return }
        let base = current.url.deletingPathExtension().lastPathComponent
        let ids = visible.filter {
            (!mark || !$0.isDirectory) && $0.url.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(base) == .orderedSame
        }.map(\.id)
        selection.saveMarks()
        shiftMarking = nil
        selection.setMarked(ids, marked: mark)
        reloadMarks()
    }
    func applyMask(_ expression: String, mark: Bool, includeDirectories: Bool = false) throws {
        if let virtualPanel { try virtualPanel.applyMask(expression, groups: maskGroups, mark: mark, includeDirectories: includeDirectories); return }
        let mask = try FileMask(expression, groups: maskGroups)
        guard !loading else { return }
        // Evaluate the complete batch before changing any marks; timeout is atomic.
        let matches = try mask.matchingNames(visible.map(\.name), timeLimit: 0.25)
        let ids = visible.filter { (!mark || includeDirectories || !$0.isDirectory) && matches.contains($0.name) }.map(\.id)
        selection.saveMarks()
        shiftMarking = nil
        selection.setMarked(ids, marked: mark)
        reloadMarks()
    }

    private var pageRowCount: Int {
        max(1, Int((table.enclosingScrollView?.contentSize.height ?? table.visibleRect.height) / (table.rowHeight + table.intercellSpacing.height)))
    }
    func automationMoveCursor(_ delta: Int) {
        if let virtualPanel { virtualPanel.moveCursor(by: delta); return }
        shiftMarking = nil
        moveCursor(to: min(max(0, table.selectedRow + delta), max(0, table.numberOfRows - 1)))
    }
    private func handleSelectionKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if !modifiers.contains(.shift) { shiftMarking = nil }
        if modifiers == [.control], event.keyCode == 46 { restoreMarks(); return true }
        if modifiers == [.option], event.keyCode == 67 { invertFilesAndClearDirectories(); return true }
        guard modifiers.isEmpty || modifiers == [.shift] else { return false }
        let next: Int
        switch event.keyCode {
        case 114, 49:
            guard modifiers.isEmpty else { return false }
            toggleMarkAndAdvance()
            return true
        case 125: next = table.selectedRow + 1
        case 126: next = table.selectedRow - 1
        case 115: next = 0
        case 119: next = table.numberOfRows - 1
        case 116: next = table.selectedRow - pageRowCount
        case 121: next = table.selectedRow + pageRowCount
        default: return false
        }
        let nextRow = min(max(next, 0), max(0, table.numberOfRows - 1))
        if modifiers.contains(.shift) {
            guard !loading else { return true }
            if shiftMarking == nil {
                selection.saveMarks()
                // Starting on `..` derives the gesture from the next real row, as in P1.
                let startEntry = cursorEntry ?? entry(at: nextRow)
                shiftMarking = !(startEntry.map { selection.markedIDs.contains($0.id) } ?? false)
            }
            // As with Shift+arrows, mark each departed row, excluding the destination.
            let start = max(table.selectedRow, 0)
            let rows: [Int]
            if nextRow > start { rows = Array(start..<nextRow) }
            else if nextRow < start { rows = Array(stride(from: start, to: nextRow, by: -1)) }
            else { rows = [start] }
            selection.setMarked(rows.compactMap { entry(at: $0)?.id }, marked: shiftMarking ?? true)
            moveCursor(to: nextRow)
            reloadMarks()
        } else { moveCursor(to: nextRow) }
        return true
    }

    private func handleSelectionMouse(_ event: NSEvent) -> Bool {
        shiftMarking = nil
        let row = table.row(at: table.convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return false }
        if loading && !event.modifierFlags.intersection([.command, .shift]).isEmpty { return true }
        if event.modifierFlags.contains(.command) {
            selection.saveMarks()
            if let entry = entry(at: row) { selection.toggle(entry.id) }
        } else if event.modifierFlags.contains(.shift) {
            selection.saveMarks()
            let anchor = max(table.selectedRow, 0)
            let marked = cursorEntry.map { !selection.markedIDs.contains($0.id) } ?? true
            let ids = (min(anchor, row)...max(anchor, row)).compactMap { entry(at: $0)?.id }
            selection.setMarked(ids, marked: marked)
        } else { return false }
        focus()
        moveCursor(to: row)
        reloadMarks()
        return true
    }

    private func moveCursor(to requestedRow: Int) {
        guard table.numberOfRows > 0 else {
            table.deselectAll(nil)
            selection.focus(nil)
            updateSummary()
            return
        }
        let row = min(max(requestedRow, 0), table.numberOfRows - 1)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        selection.focus(entry(at: row)?.id)
        table.scrollRowToVisible(row)
        updateSummary()
    }

    private func reloadMarks() {
        if sortOptions.sort == .selected {
            resortKeepingCursor()
            return
        }
        guard table.numberOfRows > 0 else { updateSummary(); return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<table.numberOfRows), columnIndexes: IndexSet(integer: 0))
        updateSummary()
    }
    func entry(at row: Int) -> FileEntry? {
        guard !isVirtual, !isResource else { return nil }
        let index = row - offset
        return visible.indices.contains(index) ? visible[index] : nil
    }
    func focus() { if isResource { resourceFocus?() } else if let virtualPanel { virtualPanel.focus() } else if let remotePanel { remotePanel.focus() } else if let archivePanel { archivePanel.focus() } else if contentMode == .files { window?.makeFirstResponder(table) } else { auxiliary.focus() } }
    func focusPath() { guard !isVirtual, !isResource else { return }; onFocus?(self); window?.makeFirstResponder(pathField); pathField.selectText(nil) }
    func focusFilter() { onFocus?(self); window?.makeFirstResponder(filterField) }
    func clearFilter() { filterField.stringValue = ""; applyFilter(); focus() }

    @objc func parent() {
        onFocus?(self)
        if isResource { if let resourceParent { resourceParent() } else { leaveResource() }; return }
        if isVirtual { leaveVirtualResults(); return }
        if isRemote { closeRemote(); return }; if isArchive { closeArchiveLevel(); return }
        if isTemporary { leaveSearchResults(); return }
        guard directory.path != "/" else { return }
        load(directory.deletingLastPathComponent(), preserveSelection: false, selectName: directory.lastPathComponent)
    }
    @objc func goToPath() {
        guard !isVirtual, !isResource else { return }
        onFocus?(self)
        let path = (pathField.stringValue as NSString).expandingTildeInPath
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)
        load(url, preserveSelection: false)
        focus()
    }
    @objc func openSelection() {
        if let virtualPanel { virtualPanel.revealSelection(); return }
        guard !loading else { return }
        if hasParent && table.selectedRow == 0 { parent(); return }
        guard let entry = cursorEntry else { return }
        if entry.isDirectory { load(entry.url, preserveSelection: false) }
        else { onFileOpen?(entry) }
    }
    func goBack() {
        if isVirtual { leaveVirtualResults(); return }
        if isRemote { closeRemote(); return }; if isArchive { closeArchiveLevel(); return }
        if isTemporary { leaveSearchResults(); return }
        guard let path = navigation.backPath, !loading else { return }
        load(URL(fileURLWithPath: path), preserveSelection: false, historyAction: .back)
    }
    func goForward() {
        if isVirtual { leaveVirtualResults(); return }
        if isRemote { closeRemote(); return }; if isArchive { closeArchiveLevel(); return }
        if isTemporary { leaveSearchResults(); return }
        guard let path = navigation.forwardPath, !loading else { return }
        load(URL(fileURLWithPath: path), preserveSelection: false, historyAction: .forward)
    }
    func navigateHistory(to path: String, focus shouldFocus: Bool = true, recordActivity: Bool = true) {
        leaveResource(focus: false)
        if isVirtual { leaveVirtualResults(focus: false) }
        if isRemote { leaveRemote(focus: false) }; if isArchive { leaveArchive(focus: false) }
        load(URL(fileURLWithPath: path), preserveSelection: false, historyAction: .visit, recordActivity: recordActivity)
        if shouldFocus { focus() }
    }
    private func persistNavigation() {
        if let data = try? JSONEncoder().encode(navigation) {
            AppPreferences.defaults.set(data, forKey: "panel.\(locationKey).history")
        }
    }

    func focusQuickFind() {
        onFocus?(self)
        quickFindField.isHidden = false
        window?.makeFirstResponder(quickFindField)
        quickFindField.selectText(nil)
    }
    private func endQuickFind(focusTable: Bool = true) {
        quickFindField.stringValue = ""
        quickFindField.isHidden = true
        if focusTable { focus() }
    }
    private func handleQuickFindKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == [.option] || modifiers == [.option, .shift], let characters = event.charactersIgnoringModifiers,
           !characters.isEmpty, characters.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) {
            focusQuickFind()
            quickFindField.stringValue = characters
            // Focus selects existing contents; put insertion at the end of the first letter.
            (quickFindField.currentEditor() as? NSTextView)?.selectedRange = NSRange(location: characters.utf16.count, length: 0)
            findQuickMatch(backwards: false, includeCurrent: true)
            return true
        }
        if !quickFindField.isHidden, event.keyCode == 53 { endQuickFind(); return true }
        if !quickFindField.isHidden, [36, 76].contains(event.keyCode),
           modifiers == [.control] || modifiers == [.control, .shift] {
            findNext(backwards: modifiers.contains(.shift))
            return true
        }
        return false
    }
    func findNext(backwards: Bool = false) { findQuickMatch(backwards: backwards, includeCurrent: false) }
    private func findQuickMatch(backwards: Bool, includeCurrent: Bool) {
        if let virtualPanel {
            do { try virtualPanel.find(quickFindField.stringValue, backwards: backwards, includeCurrent: includeCurrent) }
            catch { quickFindField.toolTip = error.localizedDescription }
            return
        }
        guard !loading, !visible.isEmpty, !quickFindField.stringValue.isEmpty else { return }
        do {
            // Quick find accepts only * and ? as wildcards; all other filename text is literal.
            let prefix = quickFindField.stringValue.precomposedStringWithCanonicalMapping.map { character -> String in
                switch character {
                case "*": return ".*"
                case "?": return "."
                default:
                    return NSRegularExpression.escapedPattern(for: String(character))
                        .replacingOccurrences(of: "/", with: "\\/")
                }
            }.joined()
            let mask = try FileMask("/^" + prefix + "/i")
            let matches = try mask.matchingNames(visible.map(\.name), timeLimit: 0.25)
            let current = visible.firstIndex { $0.id == selection.cursorID } ?? (backwards ? 0 : visible.count - 1)
            let firstStep = includeCurrent && cursorEntry != nil ? 0 : 1
            for step in firstStep..<(visible.count + firstStep) {
                let index = (current + (backwards ? -step : step) + visible.count * 2) % visible.count
                if matches.contains(visible[index].name) {
                    moveCursor(to: index + offset)
                    quickFindField.toolTip = nil
                    return
                }
            }
            quickFindField.toolTip = "Совпадений нет"
        } catch {
            quickFindField.toolTip = error.localizedDescription
        }
    }
    func controlTextDidChange(_ obj: Notification) {
        onFocus?(self)
        if let field = obj.object as? NSControl, field === quickFindField {
            // Let the field editor own IME composition and normal macOS editing keys.
            if let editor = quickFindField.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
            findQuickMatch(backwards: false, includeCurrent: true)
        } else { applyFilter() }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === quickFindField {
            if textView.hasMarkedText() { return false }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) { endQuickFind(); return true }
            let event = NSApp.currentEvent
            let modifiers = event?.modifierFlags ?? []
            // Control+Return can be translated to insertLineBreak/insertNewlineIgnoringFieldEditor.
            if modifiers.contains(.control), let key = event?.keyCode, [36, 76].contains(key) {
                findNext(backwards: modifiers.contains(.shift))
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) { focus(); return true }
            return false
        }
        guard control === filterField else { return false }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { clearFilter(); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { focus(); return true }
        return false
    }

    func setSort(_ value: FileSort) {
        var options = sortOptions
        options.sort = value
        setSortOptions(options)
    }
    func toggleSortDirection() {
        var options = sortOptions
        options.ascending.toggle()
        setSortOptions(options)
    }
    func setSortOptions(_ options: FileSortOptions) {
        if let virtualPanel { sortOptions = options; virtualPanel.setSortOptions(options); return }
        sortOptions = options
        if !isTemporary, let data = try? JSONEncoder().encode(options) {
            AppPreferences.defaults.set(data, forKey: "panel.\(locationKey).sort")
        }
        updateColumnTitles()
        resortKeepingCursor()
    }
    private func sortedEntries(_ source: [FileEntry]) -> [FileEntry] {
        let result = Self.sortedSnapshot(source, options: sortOptions, marks: selection.markedIDs, groups: sortGroups, masks: maskGroups)
        sortGroupNotice = result.1
        return result.0
    }
    nonisolated private static func sortedSnapshot(_ source: [FileEntry], options: FileSortOptions,
        marks: Set<String>, groups: SortGroups, masks: [String: String]) -> ([FileEntry], String) {
        let sorted = FileService.sorted(source, options: options, markedIDs: marks)
        guard groups.enabled, options.sort == .name || options.sort == .extension else { return (sorted, "") }
        do {
            let ranks = try groups.ranks(for: sorted.map(\.name), maskGroups: masks)
            return (sorted.enumerated().sorted { a, b in
                if options.directoriesFirst, a.element.isDirectory != b.element.isDirectory { return a.element.isDirectory }
                let ar = ranks[a.element.name] ?? 0, br = ranks[b.element.name] ?? 0
                return ar == br ? a.offset < b.offset : ar < br
            }.map(\.element), "")
        } catch { return (sorted, "Группы сортировки: " + error.localizedDescription) }
    }
    private func resortKeepingCursor() {
        guard !isVirtual, !isResource else { return }
        let gesture = shiftMarking
        entries = sortedEntries(entries)
        applyFilter()
        shiftMarking = gesture
    }

    func setDisplayMode(_ mode: PanelDisplayMode) {
        guard !isVirtual, !isResource else { return }
        displayMode = mode
        if !isTemporary { AppPreferences.defaults.set(mode.rawValue, forKey: "panel.\(locationKey).display") }
        updateColumns()
    }
    func resetColumnWidths() {
        guard !isVirtual, !isResource else { return }
        let widths = Dictionary(uniqueKeysWithValues: Self.columnDefinitions.map { ($0.id, $0.width) })
        if let saved = auxiliaryColumnLayout { auxiliaryColumnLayout = (widths, saved.autosave) }
        restoreColumnWidths(widths)
    }
    func setVisibleColumns(_ ids: Set<String>) {
        guard !isVirtual, !isResource else { return }
        customColumnIDs = ids.intersection(Set(Self.columnDefinitions.map(\.id))).union(["name"])
        customColumnIDs.remove("origin")
        if !isTemporary { AppPreferences.defaults.set(customColumnIDs.sorted(), forKey: "panel.\(locationKey).columns") }
        setDisplayMode(.custom)
    }
    func setColorizeFiles(_ enabled: Bool) {
        guard !isVirtual, !isResource else { return }
        colorizeFiles = enabled
        if !isTemporary { AppPreferences.defaults.set(enabled, forKey: "panel.\(locationKey).colorize") }
        table.reloadData()
    }
    private func updateColumns() {
        switch displayMode {
        case .brief: visibleColumnIDs = ["name"]
        case .full: visibleColumnIDs = ["name", "size", "modified", "permissions", "owner"]
        case .custom: visibleColumnIDs = customColumnIDs
        }
        if isTemporary { visibleColumnIDs.insert("origin") }
        else { visibleColumnIDs.remove("origin") }
        for column in table.tableColumns { column.isHidden = !visibleColumnIDs.contains(column.identifier.rawValue) }
        updateColumnTitles()
        table.sizeLastColumnToFit()
    }
    private func updateColumnTitles() {
        for column in table.tableColumns {
            let id = column.identifier.rawValue
            let name = Self.columnDefinitions.first { $0.id == id }?.title ?? id
            column.title = L10n.text(name) + (sortOptions.sort.rawValue == id ? (sortOptions.ascending ? " ↑" : " ↓") : "")
        }
    }
    private static let columnDefinitions: [(id: String, title: String, width: CGFloat)] = [
        ("name", "Имя", 280), ("size", "Размер", 85), ("modified", "Изменён", 125),
        ("extension", "Расширение", 90), ("created", "Создан", 125), ("accessed", "Открыт", 125),
        ("permissions", "Права", 100), ("owner", "Владелец", 100),
        ("description", "Описание", 260), ("origin", "Исходная папка", 320)
    ]

    private func applyFilter(resetSelection: Bool = false, selectName: String? = nil) {
        if let virtualPanel { virtualPanel.setFilter(filterField.stringValue); return }
        let oldRow = table.selectedRow
        let oldCursorID = selection.cursorID
        let wasParent = hasParent && oldRow == 0
        let query = filterField.stringValue
        visible = query.isEmpty ? entries : entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
        hasParent = !isTemporary && directory.path != "/" && query.isEmpty
        // Filtering also drops hidden marks so file operations cannot target unseen rows.
        selection.reconcile(validIDs: visible.map(\.id), reset: resetSelection)
        if sortOptions.sort == .selected {
            entries = sortedEntries(entries)
            visible = query.isEmpty ? entries : entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        shiftMarking = nil
        let row: Int
        if let selectName, let index = visible.firstIndex(where: { $0.name == selectName }) { row = index + offset }
        else if !resetSelection, wasParent, hasParent { row = 0 }
        else if !resetSelection, let oldCursorID, let index = visible.firstIndex(where: { $0.id == oldCursorID }) { row = index + offset }
        else { row = resetSelection ? 0 : max(oldRow, 0) }
        synchronizingTable = true
        table.reloadData()
        moveCursor(to: row)
        synchronizingTable = false
        updateSummary()
        onSelectionChange?(self)
    }
    private func updateActive() {
        layer?.borderColor = (active ? Palette.accent.withAlphaComponent(0.7) : Palette.raised).cgColor
        title.stringValue = "\(active ? "●" : "○")  \(locationKey == "left" ? "ЛЕВАЯ ПАНЕЛЬ" : "ПРАВАЯ ПАНЕЛЬ")\(active ? "  /  АКТИВНА" : "")"
        if isArchive { title.stringValue += "  /  АРХИВ" }
        if isRemote { title.stringValue += "  /  СЕТЬ" }
        if isVirtual { title.stringValue += "  /  ВРЕМЕННЫЕ РЕЗУЛЬТАТЫ" }
        resourceActivate?(active)
        archivePanel?.setActive(active); remotePanel?.setActive(active); virtualPanel?.setActive(active)
        if let temporaryTitle { title.stringValue += "  /  " + temporaryTitle }
        if contentMode != .files { title.stringValue += "  /  " + contentMode.title }
        title.textColor = active ? Palette.accent : Palette.muted
        table.enumerateAvailableRowViews { row, _ in (row as? FileRow)?.active = self.active; row.needsDisplay = true }
    }
    private func updateSummary() {
        if isResource { return }
        if isVirtual { summary.stringValue = "F7 — убрать ссылки · F8 — удалить исходные объекты"; return }
        let marked = visible.filter { selection.markedIDs.contains($0.id) }
        let count = visible.filter(\.isDirectory).count
        let total = "Папки: \(count)  ·  Файлы: \(visible.count - count)"
        if marked.isEmpty {
            summary.stringValue = total + (!isTemporary && showHidden ? "  ·  скрытые видны" : "")
        } else {
            let bytes = marked.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
            summary.stringValue = "Отмечено: \(marked.count)  ·  \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))  ·  \(total)"
        }
        if !isTemporary && !descriptionNotice.isEmpty { summary.stringValue += "  ·  " + descriptionNotice }
        if !sortGroupNotice.isEmpty { summary.stringValue += "  ·  " + sortGroupNotice }
        if isTemporary {
            summary.stringValue += "  ·  Результатов: \(entries.count)"
            if removedResultCount > 0 { summary.stringValue += "  ·  Недоступны/заменены: \(removedResultCount)" }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { visible.count + offset }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !synchronizingTable, !isVirtual else { return }
        selection.focus(entry(at: table.selectedRow)?.id)
        updateSummary()
        onSelectionChange?(self)
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = FileRow(); view.active = active; return view
    }
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let value = FileSort(rawValue: tableColumn.identifier.rawValue) else { return }
        if sortOptions.sort == value { toggleSortDirection() } else { setSort(value) }
        onFocus?(self)
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn?.identifier.rawValue else { return nil }
        let entry = entry(at: row)
        let cell = NSTableCellView()
        let text: String
        switch column {
        case "name": text = entry.map { $0.name + ($0.isSymbolicLink ? " ↗" : "") } ?? ".."
        case "size": text = entry.map { $0.isDirectory ? "<папка>" : ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file) } ?? ""
        case "extension": text = entry?.url.pathExtension ?? ""
        case "created": text = entry?.created.map { Self.dateFormatter.string(from: $0) } ?? ""
        case "accessed": text = entry?.accessed.map { Self.dateFormatter.string(from: $0) } ?? ""
        case "permissions": text = entry?.permissions ?? ""
        case "owner": text = entry?.owner ?? ""
        case "description": text = isTemporary ? "" : (entry.flatMap { descriptions[$0.name] } ?? "")
        case "origin": text = entry?.url.deletingLastPathComponent().path ?? ""
        default: text = entry?.modified.map { Self.dateFormatter.string(from: $0) } ?? ""
        }
        let field = label(text, size: 12, color: column == "name" ? entryColor(entry) : Palette.muted)
        field.translatesAutoresizingMaskIntoConstraints = false
        if isTemporary { field.toolTip = entry?.url.path }
        cell.addSubview(field)
        cell.textField = field
        var leading: CGFloat = 10
        if column == "name" {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: entry == nil ? "arrow.turn.up.left" : entry!.isDirectory ? "folder.fill" : "doc", accessibilityDescription: nil)
            icon.contentTintColor = entryColor(entry)
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            let marked = entry.map { selection.markedIDs.contains($0.id) } ?? false
            let marker = label(marked ? "✓" : "", size: 12, color: Palette.accent, bold: true)
            marker.setAccessibilityLabel(L10n.text(marked ? "Помечено" : "Не помечено"))
            marker.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(marker)
            NSLayoutConstraint.activate([
                marker.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 7),
                marker.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                marker.widthAnchor.constraint(equalToConstant: 12)
            ])
            if marked { field.textColor = Palette.accent }
            NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 25), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 15), icon.heightAnchor.constraint(equalToConstant: 15)])
            leading = 49
        }
        NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leading), field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        if column == "name", let entry {
            cell.setAccessibilityLabel(UIAccessibility.fileRow(name: entry.name, isDirectory: entry.isDirectory,
                isMarked: selection.markedIDs.contains(entry.id), isSymbolicLink: entry.isSymbolicLink))
        }
        // Cell content is a filename/metadata, never translatable UI copy.
        field.identifier = NSUserInterfaceItemIdentifier("user-content")
        UIAccessibility.apply(to: cell)
        return cell
    }
    private func entryColor(_ entry: FileEntry?) -> NSColor {
        guard let entry else { return Palette.accent }
        guard colorizeFiles, !UIPreferences.highContrast else { return Palette.text }
        if entry.isSymbolicLink { return NSColor(calibratedRed: 0.77, green: 0.62, blue: 1, alpha: 1) }
        if entry.isDirectory { return .systemCyan }
        if entry.permissions.contains("x") || entry.permissions.contains("s") || entry.permissions.contains("t") { return .systemGreen }
        if ["zip", "gz", "bz2", "xz", "7z", "rar", "tar", "tgz", "dmg", "zst"].contains(entry.url.pathExtension.lowercased()) {
            return NSColor(calibratedRed: 1, green: 0.77, blue: 0.42, alpha: 1)
        }
        return Palette.text
    }
    private static let dateFormatter: DateFormatter = {
        let value = DateFormatter(); value.dateFormat = "dd.MM.yy HH:mm"; return value
    }()
}
