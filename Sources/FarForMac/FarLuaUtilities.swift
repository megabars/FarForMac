import AppKit
import Darwin
import FarCore

// Contract reference: far/macroapi.cpp, FarGroup 1a6b0254. Native paths are POSIX.
extension FarLuaWorkspace {
    func utility(_ name: String, _ args: [FarLuaValue]) async throws -> [FarLuaValue]? {
        func string(_ i: Int) -> String { args.lua(i).hostString ?? "" }
        func integer(_ i: Int, _ fallback: Int = 0) -> Int { args.lua(i).hostInt ?? fallback }
        let directory = app?.active?.directory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        if let result = try await FarLuaFilesystem.invoke(name, arguments: args, directory: directory) { return result }
        switch name {
        case "mf.sleep", "win.Sleep":
            let ms = integer(0)
            if ms <= 0 { return [.integer(0)] }
            guard ms <= 86_400_000 else { throw ExtensionAPIError("sleep: недопустимое время") }
            try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            return [.integer(1)]
        case "mf.beep": NSSound.beep(); return [.bool(true)]
        case "mf.env":
            let old = app?.luaShell.luaEnvironment(string(0)) ?? ""
            if integer(1) != 0 { try app?.luaShell.luaSetEnvironment(string(0), string(2).isEmpty ? nil : string(2)) }
            return [.string(old)]
        case "win.GetEnv": return [app?.luaShell.luaEnvironment(string(0)).map(FarLuaValue.string) ?? .nilValue]
        case "win.SetEnv": try app?.luaShell.luaSetEnvironment(string(0), args.lua(1).hostString); return [.bool(true)]
        case "win.GetCurrentDir": return [.string(app?.active.directory.path ?? FileManager.default.currentDirectoryPath)]
        case "win.JoinPath": return [.string(args.compactMap(\.hostString).reduce("") { ($0 as NSString).appendingPathComponent($1) })]
        case "far.ConvertPath": return [.string(URL(fileURLWithPath: string(0), relativeTo: directory).standardizedFileURL.path)]
        case "mf.fmatch":
            do { return [.integer(try FileMask(string(1)).matchesChecked(string(0)) ? 1 : 0)] } catch { return [.integer(-1)] }
        case "mf.substr":
            let units = Array(string(0).utf16), requested = integer(1), start = min(units.count, max(0, requested < 0 ? units.count + requested : requested))
            let count = integer(2, units.count), length = max(0, min(units.count - start, count < 0 ? units.count - start + count : count))
            return [.string(String(decoding: units[start..<start + length], as: UTF16.self))]
        case "mf.trim":
            let mode = integer(1), text = string(0)
            if mode == 0 { return [.string(text.trimmingCharacters(in: .whitespacesAndNewlines))] }
            if mode == 1 { return [.string(String(text.drop(while: { $0.isWhitespace })))] }
            if mode == 2 { return [.string(String(text.reversed().drop(while: { $0.isWhitespace }).reversed()))] }
            return [.string(text)]
        case "mf.index", "mf.rindex":
            let needle = string(1)
            guard !needle.isEmpty else { return [.integer(-1)] }
            let text = string(0) as NSString
            var options: NSString.CompareOptions = integer(2) == 0 ? [.caseInsensitive] : []
            if name == "mf.rindex" { options.insert(.backwards) }
            let range = text.range(of: needle, options: options)
            return [.hostInteger(range.location == NSNotFound ? -1 : range.location)]
        case "mf.strpad":
            let text = string(0), fill = args.lua(2).hostString ?? " ", count = integer(1), mode = integer(3)
            guard (0...2).contains(mode), count > text.utf16.count, !fill.isEmpty else { return [.string(text)] }
            guard count <= 1_048_576 else { throw ExtensionAPIError("strpad: слишком длинная строка") }
            let missing = count - text.utf16.count, units = Array(fill.utf16)
            let padding = (0..<missing).map { units[$0 % units.count] }
            let left = mode == 1 ? missing : mode == 2 ? (text.isEmpty ? missing : missing / 2) : 0
            let right = mode == 0 || mode == 2 ? missing - left : 0
            return [.string(String(decoding: padding.prefix(left), as: UTF16.self) + text + String(decoding: padding.prefix(right), as: UTF16.self))]
        case "mf.atoi":
            let radix = integer(1)
            guard radix == 0 || (2...36).contains(radix) else { return [.integer(0)] }
            let text = string(0)
            let value = text.withCString { source -> Int64 in
                errno = 0
                var end: UnsafeMutablePointer<CChar>?
                let number = strtoll(source, &end, Int32(radix))
                guard errno != ERANGE, let end, UnsafePointer(end) != source else { return 0 }
                return number
            }
            return [.integer(value)]
        case "mf.itoa":
            guard let value = args.lua(0).hostInt else { return [args.lua(0)] }
            let requested = integer(1)
            let radix = (2...36).contains(requested) ? requested : 10
            return [.string(radix == 10 ? String(value) : String(UInt64(bitPattern: Int64(value)), radix: radix))]
        case "mf.clip":
            switch integer(0) {
            case 0: return [.string(NSPasteboard.general.string(forType: .string) ?? "")]
            case 1: NSPasteboard.general.clearContents(); return [.integer(NSPasteboard.general.setString(string(1), forType: .string) ? 1 : 0)]
            case 2:
                let text = (NSPasteboard.general.string(forType: .string) ?? "") + string(1)
                NSPasteboard.general.clearContents(); return [.integer(NSPasteboard.general.setString(text, forType: .string) ? 1 : 0)]
            default: throw ExtensionAPIError("Внутренние буферы mf.clip пока не перенесены")
            }
        case "mf.usermenu":
            if args.lua(0) != .nilValue, args.lua(0).hostInt == nil { return [] }
            let flags = integer(0)
            guard flags & 255 == 0 else { throw ExtensionAPIError("mf.usermenu: этот источник меню ещё не подключён.") }
            if flags & 0x100 != 0 { app?.luaShell.showUserMenu(); return [] }
            return try await host("Keys", [.string("F2")])
        case "Panel.SetPath":
            guard let app else { return [.bool(false)] }
            let active = integer(0) == 0
            guard await app.luaNavigate(string(1), active: active) else { return [.bool(false)] }
            let panel = active ? app.active! : app.passive
            if let filename = args.lua(2).hostString {
                let info = try panel.luaPanelCall("panel.GetPanelInfo", [.nilValue, .integer(active ? 1 : 0)]).first?.hostTable ?? [:]
                for row in 1...max(1, info["ItemsNumber"]?.hostInt ?? 0) {
                    let item = try panel.luaPanelCall("panel.GetPanelItem", [.nilValue, .integer(active ? 1 : 0), .hostInteger(row)]).first?.hostTable
                    if item?["FileName"]?.hostString?.caseInsensitiveCompare(filename) == .orderedSame {
                        _ = try panel.luaPanelCall("panel.RedrawPanel", [.nilValue, .integer(active ? 1 : 0), .table(["CurrentItem":.hostInteger(row), "TopPanelItem":.integer(1)])]); break
                    }
                }
            }
            return [.bool(true)]
        case "Panel.Item", "Panel.FExist", "Panel.FAttr", "Panel.SetPos", "Panel.SetPosIdx", "Panel.Select":
            guard let app else { return [.integer(0)] }
            let panel = integer(0) == 0 ? app.active! : app.passive
            return try panel.luaMacroPanelCall(name, args)
        default: return nil
        }
    }
}
