import AppKit
import FarCore

/// LuaFAR's row indices address the live panel table. The view remains the
/// owner of row identity, cursor, viewport and marks.
typealias FarLuaPanelMarkChange = (row: Int, marked: Bool)

@MainActor
struct FarLuaBuiltinPanel {
    struct Item {
        var name: String
        var directory: Bool
        var size: Int64 = 0
        var symbolicLink = false
        var encrypted = false
        var marked = false
        var origin: String?

        var luaValue: FarLuaValue {
            var attributes = directory ? "d" : ""
            if symbolicLink { attributes += "l" }
            if encrypted { attributes += "e" }
            var values: [String: FarLuaValue] = [
                "FileName": .string(name), "FileSize": .integer(size), "FileAttributes": .string(attributes),
                "Flags": .integer(marked ? 0x4000_0000 : 0)
            ]
            if let origin { values["CustomColumnData"] = .array([.string(origin)]) }
            return .table(values)
        }
    }

    let table: NSTableView
    let active: Bool
    let path: String
    let fullPath: String
    let root: Bool
    let format: String?
    let hostFile: String?
    let prefix: String?
    let sortMode: Int?
    let directoriesFirst: Bool
    let ascending: Bool
    let selectedFirst: Bool
    let filtered: Bool
    let parentRow: Bool
    let markedRows: () -> [Int]
    let item: (Int) -> Item?
    let move: (Int) -> Void
    let mark: ([FarLuaPanelMarkChange]) -> Void

    private var count: Int { table.numberOfRows }
    private var current: Int { table.selectedRow }
    private var visible: Bool { !table.isHiddenOrHasHiddenAncestor }
    private var selection: [Int] {
        let marks = markedRows()
        if !marks.isEmpty { return marks }
        return current >= (parentRow ? 1 : 0) && current < count ? [current] : []
    }
    private var topRow: Int {
        let visibleRows = table.rows(in: table.visibleRect)
        return visibleRows.length == 0 ? 0 : visibleRows.location
    }

    var properties: FarLuaValue {
        let row = item(current)
        let marks = markedRows()
        let font = NSFont.monospacedSystemFont(ofSize: UIPreferences.fontSize(12), weight: .regular)
        let cellWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
        return .table([
            "Path": .string(path), "Path0": .string(path), "UNCPath": .string(fullPath),
            "Current": .string(row?.name ?? ""), "CurPos": .hostInteger(current + 1),
            "ItemCount": .hostInteger(count), "SelCount": .hostInteger(marks.count),
            "Selected": .bool(!marks.isEmpty), "Plugin": .bool(true), "FilePanel": .bool(true),
            "Folder": .bool(row?.directory == true), "Empty": .bool(count <= (parentRow ? 1 : 0)),
            "Bof": .bool(current <= 0), "Eof": .bool(current + 1 >= count), "Root": .bool(root),
            "Visible": .bool(visible), "Filter": .bool(filtered), "Type": .integer(0), "DriveType": .integer(-1),
            "ColumnCount": .hostInteger(table.tableColumns.count),
            "Width": .hostInteger(Int(table.visibleRect.width / cellWidth)),
            "Height": .hostInteger(Int(table.visibleRect.height / max(1, table.rowHeight))),
            "HostFile": .string(hostFile ?? ""), "Prefix": .string(prefix ?? ""), "Format": .string(format ?? "")
        ])
    }

    func call(_ name: String, _ arguments: [FarLuaValue], left: Bool) throws -> [FarLuaValue] {
        let argument = arguments.lua(2)
        switch name {
        case "panel.GetPanelInfo":
            var flags = 0x800
            if visible { flags |= 0x1000 }
            if active { flags |= 0x2000 }
            if left { flags |= 0x80 }
            if directoriesFirst { flags |= 0x100 }
            if !ascending { flags |= 4 }
            if selectedFirst { flags |= 0x10 }
            var info: [String: FarLuaValue] = [
                "PanelType": .integer(0), "ItemsNumber": .hostInteger(count),
                "SelectedItemsNumber": .hostInteger(selection.count), "CurrentItem": .hostInteger(current + 1),
                "TopPanelItem": .hostInteger(topRow + 1), "Flags": .hostInteger(flags)
            ]
            if let sortMode { info["SortMode"] = .hostInteger(sortMode) }
            return [.table(info)]
        case "panel.GetPanelDirectory":
            return [.table(["Name": .string(path), "Param": .string(""), "File": .string(hostFile ?? "")])]
        case "panel.GetCurrentPanelItem":
            return [item(current)?.luaValue ?? .nilValue]
        case "panel.GetPanelItem", "panel.GetSelectedPanelItem":
            guard let index = argument == .nilValue ? 1 : argument.hostInt else {
                throw ExtensionAPIError("\(name): индекс должен быть числом.")
            }
            guard index > 0 else { return [.nilValue] }
            if name == "panel.GetPanelItem" { return [item(index - 1)?.luaValue ?? .nilValue] }
            let rows = selection
            guard rows.indices.contains(index - 1) else { return [.nilValue] }
            return [item(rows[index - 1])?.luaValue ?? .nilValue]
        case "panel.RedrawPanel":
            let redraw = argument.hostTable
            if let index = redraw["CurrentItem"]?.hostInt, index > 0, count > 0 {
                move(min(index, count) - 1)
            }
            if let index = redraw["TopPanelItem"]?.hostInt, index > 0, index <= count,
               let scroll = table.enclosingScrollView {
                let clip = scroll.contentView
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: table.rect(ofRow: index - 1).minY))
                scroll.reflectScrolledClipView(clip)
            }
            table.needsDisplay = true
            return [.bool(true)]
        case "panel.SetSelection", "panel.ClearSelection":
            let requested: [Int]
            switch argument {
            case .array(let values): requested = values.compactMap(\.hostInt)
            case .table: requested = []
            default:
                guard let value = argument.hostInt, value > 0 else {
                    throw ExtensionAPIError("\(name): требуется положительный индекс или таблица индексов.")
                }
                requested = [value]
            }
            let clearing = name == "panel.ClearSelection"
            let selected = selection
            let rows = requested.compactMap { index -> Int? in
                guard index > 0 else { return nil }
                if clearing { return selected.indices.contains(index - 1) ? selected[index - 1] : nil }
                return index <= count && (!parentRow || index > 1) ? index - 1 : nil
            }
            if !rows.isEmpty {
                let marked = !clearing && arguments.lua(3).hostBool
                mark(rows.map { (row: $0, marked: marked) })
            }
            return [.bool(true)]
        case "panel.GetPanelFormat": return [format.map(FarLuaValue.string) ?? .nilValue]
        case "panel.GetPanelHostFile": return [hostFile.map(FarLuaValue.string) ?? .nilValue]
        case "panel.GetPanelPrefix": return [prefix.map(FarLuaValue.string) ?? .nilValue]
        default: throw ExtensionAPIError("API пока не перенесён: \(name)")
        }
    }
}

extension FarLuaBuiltinPanel {
    static func runUISmokeChecks(in root: URL) throws -> [String] {
        let directory = root.appendingPathComponent("lua-built-in-panels-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let alpha = directory.appendingPathComponent("alpha.txt")
        let beta = directory.appendingPathComponent("beta.txt")
        try Data("alpha".utf8).write(to: alpha)
        try Data("beta".utf8).write(to: beta)
        let archive = ArchivePanelView(snapshot: try ArchiveWriter.create(sources: [alpha, beta],
            destination: directory.appendingPathComponent("fixture.zip"), format: .zip))
        let provider = ProviderUISmokeFixture()
        let remote = RemotePanelView(provider: provider, path: "/docs", entries: [
            .init(path: "/docs/alpha.txt", isDirectory: false, size: 5),
            .init(path: "/docs/beta.txt", isDirectory: false, size: 4)
        ])
        let temporary = try VirtualResultsPanelView(results: [.local(try SearchResult.capture(alpha)), .local(try SearchResult.capture(beta))])

        typealias PanelCall = (String, [FarLuaValue], Bool) throws -> [FarLuaValue]
        func check(_ label: String, _ call: PanelCall, property: () -> FarLuaValue, firstIndex: Int) throws {
            let args: [FarLuaValue] = [.nilValue, .integer(1)]
            let first = FarLuaValue.hostInteger(firstIndex)
            let second = FarLuaValue.hostInteger(firstIndex + 1)
            let info = try call("panel.GetPanelInfo", args, true).lua(0).hostTable
            guard info["ItemsNumber"]?.hostInt == firstIndex + 1,
                  (info["Flags"]?.hostInt ?? 0) & 0x880 == 0x880,
                  try call("panel.GetPanelItem", args + [.integer(.min)], true) == [.nilValue],
                  try call("panel.GetPanelItem", args + [first], true).lua(0).hostTable["FileName"]?.hostString == "alpha.txt" else {
                throw PanelSessionError("LuaFAR \(label) panel returned incorrect indexed rows or flags")
            }
            func currentName() throws -> String? {
                try call("panel.GetCurrentPanelItem", args, true).lua(0).hostTable["FileName"]?.hostString
            }
            _ = try call("panel.RedrawPanel", args + [.table(["CurrentItem": second])], true)
            guard try currentName() == "beta.txt" else {
                throw PanelSessionError("LuaFAR \(label) redraw did not move the cursor to beta.txt")
            }
            _ = try call("panel.SetSelection", args + [.array([first, second]), .bool(true)], true)
            let cursor = try currentName(), count = property().hostTable["SelCount"]?.hostInt
            let selected = try call("panel.GetSelectedPanelItem", args + [.integer(2)], true).lua(0).hostTable
            guard cursor == "beta.txt", count == 2, selected["FileName"]?.hostString == "beta.txt",
                  selected["Flags"]?.hostInt == 0x4000_0000 else {
                throw PanelSessionError("LuaFAR \(label) SetSelection returned cursor \(cursor ?? "nil"), mark count \(count ?? -1) and selected row \(selected)")
            }
            _ = try call("panel.ClearSelection", args + [.integer(2)], true)
            guard property().hostTable["SelCount"]?.hostInt == 1,
                  try currentName() == "beta.txt",
                  try call("panel.GetSelectedPanelItem", args, true).lua(0).hostTable["FileName"]?.hostString == "alpha.txt" else {
                throw PanelSessionError("LuaFAR \(label) ClearSelection must preserve the cursor and address selected-item ordinals")
            }
        }

        try check("archive", archive.luaPanelCall, property: { archive.luaPanelProperties }, firstIndex: 2)
        try check("remote", remote.luaPanelCall, property: { remote.luaPanelProperties }, firstIndex: 2)
        try check("mixed", temporary.luaPanelCall, property: { temporary.luaPanelProperties }, firstIndex: 1)
        let args: [FarLuaValue] = [.nilValue, .integer(1)]
        guard try archive.luaPanelCall("panel.GetPanelFormat", args) == [.string("ZIP")],
              try archive.luaPanelCall("panel.GetPanelHostFile", args) == [.string(archive.snapshot.sourceURL.path)],
              try remote.luaPanelCall("panel.GetPanelDirectory", args).lua(0).hostTable["Name"]?.hostString == "/docs",
              try remote.luaPanelCall("panel.GetPanelFormat", args) == [.string(provider.connection.kind.rawValue)],
              try remote.luaPanelCall("panel.GetPanelPrefix", args) == [.nilValue],
              try temporary.luaPanelCall("panel.GetPanelItem", args).lua(0).hostTable["CustomColumnData"]?.hostArray == [.string(alpha.path)] else {
            throw PanelSessionError("LuaFAR panel metadata must reflect real host paths, providers, and virtual source columns")
        }
        return ["LuaFAR archive, remote and mixed panels expose live rows, cursor and marked-item ordinals"]
    }
}
