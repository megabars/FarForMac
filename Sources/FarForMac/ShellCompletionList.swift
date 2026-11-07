import AppKit
import FarCore

@MainActor
final class ShellCompletionList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let popover = NSPopover()
    private let table = NSTableView()
    private var candidates: [ShellCompletionCandidate] = []
    var onChoose: ((String) -> Void)?
    var isShown: Bool { popover.isShown }

    override init() {
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 23
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(chooseClicked)
        table.setAccessibilityLabel("Дополнения команды")
        let scroller = NSScrollView()
        scroller.documentView = table
        scroller.hasVerticalScroller = true
        let controller = NSViewController()
        controller.view = scroller
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = false
    }

    func show(_ candidates: [ShellCompletionCandidate], at input: NSTextField, selectFirst: Bool) {
        guard input.window?.isVisible == true, !candidates.isEmpty else { dismiss(); return }
        self.candidates = candidates
        table.reloadData()
        table.deselectAll(nil)
        if selectFirst { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        let size = NSSize(width: max(320, input.bounds.width), height: min(230, max(24, CGFloat(candidates.count) * 24)))
        table.tableColumns.first?.width = size.width - 5
        popover.contentSize = size
        if !popover.isShown { popover.show(relativeTo: input.bounds, of: input, preferredEdge: .maxY) }
    }

    func dismiss() {
        popover.close()
        candidates.removeAll()
    }

    func move(backward: Bool) {
        guard !candidates.isEmpty else { return }
        let previous = table.selectedRow
        let next: Int
        if previous < 0 { next = backward ? candidates.count - 1 : 0 }
        else { next = (previous + (backward ? -1 : 1) + candidates.count) % candidates.count }
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    func chooseSelected() -> Bool {
        guard isShown, candidates.indices.contains(table.selectedRow) else { return false }
        let value = candidates[table.selectedRow].command
        dismiss()
        onChoose?(value)
        return true
    }

    @objc private func chooseClicked() { _ = chooseSelected() }

    func numberOfRows(in tableView: NSTableView) -> Int { candidates.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard candidates.indices.contains(row) else { return nil }
        let candidate = candidates[row]
        let display = candidate.command.replacingOccurrences(of: "\n", with: "↵").replacingOccurrences(of: "\r", with: "↵")
        let field = NSTextField(labelWithString: Self.title(candidate.source) + " · " + display)
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }

    static func title(_ source: ShellCompletionSource) -> String {
        switch source {
        case .history: return "История"
        case .filesystem: return "Файлы"
        case .environment: return "Окружение"
        case .path: return "PATH"
        }
    }
}
