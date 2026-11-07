import AppKit
import FarCore

/// FAR 1a6b0254: luafar/lf_{editor,viewer}.c, far/plugapi.cpp:1683–1945,
/// far/fileedit.cpp:527–832, far/editor.cpp:5089, and far/manager.cpp:349–398.
@MainActor
enum FarLuaDocumentHost {
    private enum EditorExit: Int64 {
        case openError = 0, modified = 1, notModified = 2, interrupted = 3
        var result: [FarLuaValue] { [.integer(rawValue)] }
    }

    private enum OpenMode: Int64 {
        case query = 0, new = 0x10000000, current = 0x20000000
        case breakIfOpen = 0x30000000, reload = 0x40000000
    }

    private struct Options {
        let title: String?
        let encoding: ViewerEncoding
        let useRememberedEncoding: Bool
        let nonmodal: Bool
        let immediate: Bool
        let enableF6: Bool
        let recordHistory: Bool
        let createUnnamed: Bool
        let locked: Bool
        let savePosition: Bool
        let openMode: OpenMode

        @MainActor init(_ args: [FarLuaValue], editor: Bool) throws {
            let api = editor ? "editor.Editor" : "viewer.Viewer"
            let geometry = try [0, 0, -1, -1].enumerated().map { index, value in
                try FarLuaDocumentHost.integer(args.lua(index + 2), default: value, api: api)
            }
            guard geometry == [0, 0, -1, -1] else {
                throw ExtensionAPIError("\(api): координаты консольного окна Windows не поддерживаются")
            }
            let flags = try FarLuaDocumentHost.parseFlags(args.lua(6), prefix: editor ? "EF_" : "VF_", api: api)
            let deleteFlag: Int64 = editor ? 0x10 : 0x02
            guard flags & (deleteFlag | 0x0200) == 0 else {
                throw ExtensionAPIError("\(api): флаги удаления файла при закрытии не поддерживаются")
            }
            let supported: Int64 = editor ? 0xF0000D0F : 0x010D
            guard flags & ~supported == 0, let mode = OpenMode(rawValue: flags & 0xF0000000) else {
                throw ExtensionAPIError("\(api): неподдерживаемые флаги \(String(flags, radix: 16))")
            }
            let codePage = try FarLuaDocumentHost.integer(args.lua(editor ? 9 : 7), default: -1, api: api)
            let encodings: [Int: ViewerEncoding] = [-2: .automatic, -1: .automatic, 65001: .utf8,
                1200: .utf16LE, 1201: .utf16BE, 1251: .windows1251, 1252: .windows1252,
                28591: .latin1, 437: .dos437, 866: .dos866]
            if codePage == 0 || codePage == 1 {
                encoding = TextDocumentDialogs.systemCodePages[codePage]
            } else if let encoding = encodings[codePage] {
                self.encoding = encoding
            } else {
                throw ExtensionAPIError("\(api): кодовая страница \(codePage) не поддерживается")
            }
            title = args.lua(1).hostString.flatMap { $0.isEmpty ? nil : $0 }
            useRememberedEncoding = codePage == -1
            nonmodal = flags & 1 != 0 && NSApp.modalWindow == nil
            immediate = nonmodal && flags & 0x100 != 0
            enableF6 = flags & 4 != 0
            recordHistory = flags & 8 == 0
            createUnnamed = editor && flags & 2 != 0
            locked = editor && flags & 0x400 != 0
            savePosition = flags & 0x800 == 0
            openMode = mode
        }
    }

    private static var waitingCount = 0
    static var isWaitingForDocument: Bool { waitingCount > 0 }

    static func call(_ name: String, _ args: [FarLuaValue], app: AppDelegate) async throws -> [FarLuaValue] {
        try Task.checkCancellation()
        switch name {
        case "editor.Editor": return try await edit(args, app: app)
        case "viewer.Viewer": return [.bool(try await view(args, app: app))]
        default: throw ExtensionAPIError("Неподдерживаемый вызов окна FAR \(name)")
        }
    }

    private static func integer(_ arg: FarLuaValue, default defaultValue: Int, api: String) throws -> Int {
        if arg == .nilValue { return defaultValue }
        guard let value = arg.hostInt else { throw ExtensionAPIError("\(api): ожидалось число") }
        return value
    }

    private static func parseFlags(_ arg: FarLuaValue, prefix: String, api: String) throws -> Int64 {
        if arg == .nilValue { return 0 }
        if let number = arg.hostInt { return Int64(number) }
        guard let names = arg.hostString else { throw ExtensionAPIError("\(api): ожидались флаги FAR") }
        var flags: Int64 = 0
        for token in names.split(whereSeparator: { $0.isWhitespace || $0 == "|" }) {
            let name = String(token)
            // The LuaFAR ABI publishes EN_NONE for the editor's zero mask.
            if prefix == "EF_", name == "EN_NONE" { continue }
            guard name.hasPrefix(prefix), let flag = FarLuaFlags.values[name] else {
                throw ExtensionAPIError("\(api): неизвестный флаг \(name)")
            }
            flags |= flag
        }
        return flags
    }

    private static func pathURL(_ path: String, directory: URL) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return directory.appendingPathComponent(path).standardizedFileURL
    }

    private static func edit(_ args: [FarLuaValue], app: AppDelegate) async throws -> [FarLuaValue] {
        let options = try Options(args, editor: true)
        let startLine = try integer(args.lua(7), default: -1, api: "editor.Editor")
        let startColumn = try integer(args.lua(8), default: -1, api: "editor.Editor")
        guard startLine >= -2, startColumn >= -1 else {
            throw ExtensionAPIError("editor.Editor: недопустимая начальная позиция")
        }
        guard let path = args.lua(0).hostString, !path.utf8.contains(0),
              !path.isEmpty || options.createUnnamed else { return EditorExit.openError.result }
        let directory = app.active.directory
        let url = path.isEmpty ? nil : pathURL(path, directory: directory)
        var replaced: TextFileWindow?
        if let url, let existing = app.luaEditor(for: url) ?? app.luaEditor(for: url.resolvingSymlinksInPath()) {
            var mode = options.openMode
            if mode == .query {
                guard let decision = queryExisting(url, nonmodal: options.nonmodal) else { return EditorExit.interrupted.result }
                mode = decision
            }
            switch mode {
            case .breakIfOpen where options.nonmodal:
                // XC_EXISTS without activation. The pinned build has mantis_2562 disabled.
                return EditorExit.modified.result
            case .current, .breakIfOpen:
                existing.showWindow(nil)
                return (options.nonmodal ? EditorExit.modified : .interrupted).result
            case .reload:
                guard options.nonmodal else {
                    existing.showWindow(nil)
                    return EditorExit.interrupted.result
                }
                replaced = existing
            case .new, .query: break
            }
        }

        let onView = viewAction(app: app, options: options)
        let editor: TextFileWindow
        do {
            if let url, FileManager.default.fileExists(atPath: url.path) {
                let byteOffset = startLine == -2 ? Int64(max(0, startColumn)) : nil
                editor = try TextFileWindow(url: url, editable: !options.locked, initialByteOffset: byteOffset,
                    encoding: options.encoding, useRememberedEncoding: options.useRememberedEncoding, onView: onView)
            } else {
                // A missing named path is a new document in FAR even without EF_CREATENEW.
                if let url {
                    editor = TextFileWindow(newAt: url, encoding: options.encoding, editable: !options.locked, onView: onView)
                } else {
                    let format = EditorFormat(encoding: options.encoding == .automatic ? .utf8 : options.encoding)
                    editor = TextFileWindow(newIn: directory, format: format, editable: !options.locked, onView: onView)
                }
            }
        } catch { return EditorExit.openError.result }
        editor.luaConfigureOpen(title: options.title, startLine: startLine, startColumn: startColumn, savePosition: options.savePosition)
        replaced?.luaDiscardForReopen()
        app.farCmdsRegister(editor)
        if options.recordHistory, let url { app.luaShell.recordActivity(.edit, value: url.path) }
        editor.showWindow(nil)
        if options.immediate { return EditorExit.modified.result }
        guard let window = editor.window else { return EditorExit.openError.result }
        try await waitForDocument(window, nonmodal: options.nonmodal, isClosed: { editor.luaDocumentIsClosed })
        // ExecuteNonModal reports NOT_MODIFIED once the manager has removed the window.
        if options.nonmodal && editor.luaDocumentIsClosed { return EditorExit.notModified.result }
        return (editor.luaFileWasSaved ? EditorExit.modified : .notModified).result
    }

    private static func queryExisting(_ url: URL, nonmodal: Bool) -> OpenMode? {
        let alert = NSAlert()
        alert.messageText = "Редактор"
        alert.informativeText = "\(url.path)\nФайл уже открыт. Как его открыть?"
        let choices: [(String, OpenMode?)] = nonmodal
            ? [("Текущий", .current), ("Новый", .new), ("Перечитать", .reload), ("Отмена", nil)]
            : [("Новый", .new), ("Отмена", nil)]
        for choice in choices {
            let button = alert.addButton(withTitle: choice.0)
            if choice.1 == nil { button.keyEquivalent = "\u{1b}" }
        }
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return choices.indices.contains(index) ? choices[index].1 : nil
    }

    private static func view(_ args: [FarLuaValue], app: AppDelegate) async throws -> Bool {
        let options = try Options(args, editor: false)
        guard let path = args.lua(0).hostString, !path.isEmpty, !path.utf8.contains(0) else { return false }
        let url = pathURL(path, directory: app.active.directory)
        guard let viewer = try? makeViewer(url, offset: nil, encoding: options.encoding, app: app, options: options),
              let window = viewer.window else { return false }
        do {
            // The caller gets true only after an actual source and initial page were opened.
            let info = try await viewer.luaViewerCall("viewer.GetInfo", [])
            guard info.lua(0) != .nilValue else { window.close(); return false }
        } catch {
            window.close()
            throw error
        }
        app.farCmdsRegister(viewer)
        if options.recordHistory { app.luaShell.recordActivity(.view, value: url.path) }
        viewer.showWindow(nil)
        if options.immediate { return true }
        try await waitForDocument(window, nonmodal: options.nonmodal, isClosed: { viewer.luaDocumentIsClosed })
        return options.nonmodal || !viewer.luaDidSwitchToEditor
    }

    private static func makeViewer(_ url: URL, offset: Int64?, encoding: ViewerEncoding, app: AppDelegate, options: Options) throws -> ViewerWindow {
        try ViewerWindow(url: url, initialByteOffset: offset, initialEncoding: encoding,
            useRememberedEncoding: options.useRememberedEncoding, allowsEdit: options.enableF6, customTitle: options.title,
            onEdit: { [weak app] url, offset, encoding in
                guard let app, let editor = try? TextFileWindow(url: url, initialByteOffset: offset, encoding: encoding,
                    onView: viewAction(app: app, options: options)) else { return false }
                editor.luaConfigureOpen(title: options.title, savePosition: options.savePosition)
                app.farCmdsRegister(editor)
                if options.recordHistory { app.luaShell.recordActivity(.edit, value: url.path) }
                editor.showWindow(nil)
                return true
            })
    }

    private static func viewAction(app: AppDelegate, options: Options) -> ((URL, Int64, ViewerEncoding) -> Bool)? {
        guard options.enableF6 else { return nil }
        return { [weak app] url, offset, encoding in
            guard let app, let viewer = try? makeViewer(url, offset: offset, encoding: encoding, app: app, options: options) else { return false }
            app.farCmdsRegister(viewer)
            if options.recordHistory { app.luaShell.recordActivity(.view, value: url.path) }
            viewer.showWindow(nil)
            return true
        }
    }

    private static func waitForDocument(_ window: NSWindow, nonmodal: Bool, isClosed: () -> Bool) async throws {
        waitingCount += 1
        defer { waitingCount -= 1 }
        let session = nonmodal ? nil : NSApp.beginModalSession(for: window)
        defer { if let session { NSApp.endModalSession(session) } }
        var wasKey = window.isKeyWindow
        while !isClosed() {
            try Task.checkCancellation()
            if let session { _ = NSApp.runModalSession(session) }
            else {
                let key = NSApp.keyWindow
                if key === window { wasKey = true }
                if wasKey, let key, key !== window, NSApp.modalWindow == nil, window.attachedSheet == nil { return }
            }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
    }
}

extension FarLuaDocumentHost {
    static func runUISmokeChecks(app: AppDelegate) async throws -> [String] {
        guard AppRuntime.isSmoke, let root = AppRuntime.smokeStateDirectory else {
            throw ExtensionAPIError("Lua document smoke requires isolated state.")
        }
        let directory = root.appendingPathComponent("lua-document-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("input.txt")
        let original = Data([0xc6, 13, 10, 9, 120, 121, 13, 10, 90])
        try original.write(to: file)

        let host = FarLuaWorkspace.shared
        func run(_ source: String) async throws -> [FarLuaValue] {
            let runtime = try FarLuaRuntime()
            let step = try runtime.startChunk(source: "local F = far.Flags\n" + source,
                name: "document-host-smoke.lua", language: .lua, snapshot: host.snapshot())
            return try await host.drive(step, runtime: runtime)
        }
        func waitUntil(_ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(3)
            while !predicate() {
                guard Date() < deadline else { throw ExtensionAPIError("Lua document smoke timed out while opening a window.") }
                try await Task.sleep(nanoseconds: 15_000_000)
            }
        }
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw ExtensionAPIError(message) }
        }
        func sendF6(_ window: NSWindow) async throws {
            try await app.focusSmokeWindow(window)
            NSApp.sendEvent(try FarLuaKeys.event("F6", window: window))
        }
        // NSAlert.runModal processes timers in the AppKit modal-panel run-loop mode.
        func cancelNativeClose(_ window: NSWindow) -> Bool {
            func cancelButton(in view: NSView) -> NSButton? {
                if let button = view as? NSButton, button.title == "Отмена" { return button }
                return view.subviews.lazy.compactMap(cancelButton(in:)).first
            }
            var pressed = false
            let deadline = Date().addingTimeInterval(2)
            let timer = Timer(timeInterval: 0.025, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard let modal = NSApp.modalWindow, modal !== window else { return }
                    if let content = modal.contentView, let button = cancelButton(in: content) {
                        pressed = true
                        button.performClick(nil)
                    } else if Date() >= deadline {
                        NSApp.stopModal(withCode: .init(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 2))
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            defer { timer.invalidate() }
            window.performClose(nil)
            return pressed
        }

        let path = file.path
        var returned = false
        let edit = Task { @MainActor in
            defer { returned = true }
            return try await run("return editor.Editor([=[\(path)]=], 'Lua modal editor', nil,nil,nil,nil, F.EF_IMMEDIATERETURN,2,5,1251)")
        }
        defer { edit.cancel() }
        try await waitUntil { returned || app.luaEditor(for: file) != nil }
        guard !returned, let editor = app.luaEditor(for: file), let window = editor.window else {
            throw ExtensionAPIError("A default Lua editor call returned before closing its modal window.")
        }
        defer { editor.closeArchiveWorkingCopyWithoutSaving() }
        try require(NSApp.modalWindow === window && isWaitingForDocument && window.title == "Lua modal editor",
            "Lua editor did not establish a native modal session or apply its title.")
        let position = try editor.luaEditorCall("editor.GetInfo", []).lua(0).hostTable
        try require(position["CurLine"] == .integer(2) && position["CurTabPos"] == .integer(5) && position["CodePage"] == .integer(1251),
            "Lua editor opening coordinates or code page did not reach the actual document.")
        let changed = try editor.luaEditorCall("editor.SetString", [.nilValue, .integer(2), .string("changed")])
        try require(changed == [.bool(true)] && cancelNativeClose(window) && window.isVisible && !returned,
            "Cancel in the editor close confirmation ended the document call.")
        editor.saveDocument(nil)
        window.performClose(nil)
        let edited = try await edit.value
        let saved = try Data(contentsOf: file)
        try require(edited == [.integer(1)] && saved != original, "Lua modal editor failed to report an actual save.")

        let locked = try await run("return editor.Editor([=[\(path)]=], 'Lua locked editor', nil,nil,nil,nil, 'EF_NONMODAL EF_IMMEDIATERETURN EF_LOCKED')")
        guard let readonly = app.luaEditor(for: file), let readWindow = readonly.window else {
            throw ExtensionAPIError("Lua nonmodal editor did not create a visible window.")
        }
        defer { readonly.closeArchiveWorkingCopyWithoutSaving() }
        let refused = try readonly.luaEditorCall("editor.SetString", [.nilValue, .integer(1), .string("unsafe")])
        let current = try await run("return editor.Editor([=[\(path)]=], nil,nil,nil,nil,nil, F.EF_NONMODAL+F.EF_OPENMODE_USEEXISTING)")
        try require(locked == [.integer(1)] && refused == [.bool(false)] && current == [.integer(1)] &&
                    !readonly.isEditable && app.luaEditor(for: file) === readonly,
            "Lua editor flags failed to open immediately, lock edits, or reuse the existing document.")
        try await sendF6(readWindow)
        try require(readWindow.isKeyWindow && !readonly.luaDocumentIsClosed,
            "Lua editor accepted F6 without EF_ENABLE_F6.")
        readWindow.performClose(nil)

        let newFile = directory.appendingPathComponent("new.txt")
        let newPath = newFile.path
        var newReturned = false
        let newDocument = Task { @MainActor in
            defer { newReturned = true }
            return try await run("return editor.Editor([=[\(newPath)]=], nil,nil,nil,nil,nil, F.EF_NONMODAL)")
        }
        defer { newDocument.cancel() }
        try await waitUntil { newReturned || app.luaEditor(for: newFile) != nil }
        guard !newReturned, let newEditor = app.luaEditor(for: newFile), let newWindow = newEditor.window else {
            throw ExtensionAPIError("Lua nonmodal editor without immediate-return did not wait for a new document.")
        }
        defer { newEditor.closeArchiveWorkingCopyWithoutSaving() }
        newWindow.performClose(nil)
        let untouched = try await newDocument.value
        try require(untouched == [.integer(2)] && !FileManager.default.fileExists(atPath: newPath),
            "Closing an untouched new Lua editor created a file or reported a modification.")

        var viewerReturned = false
        let view = Task { @MainActor in
            defer { viewerReturned = true }
            return try await run("return viewer.Viewer([=[\(path)]=], 'Lua modal viewer', nil,nil,nil,nil, 0, 1251)")
        }
        defer { view.cancel() }
        try await waitUntil { viewerReturned || NSApp.modalWindow?.windowController is ViewerWindow }
        guard !viewerReturned, let viewer = NSApp.modalWindow?.windowController as? ViewerWindow,
              let viewWindow = viewer.window else { throw ExtensionAPIError("Lua viewer did not wait for its modal window.") }
        defer { viewWindow.close() }
        try require(viewWindow.title == "Lua modal viewer" && viewer.luaViewerInfo.hostTable["CurMode"]?.hostTable["CodePage"] == .integer(1251),
            "Lua viewer failed to apply the requested title or code page.")
        try await sendF6(viewWindow)
        try require(viewWindow.isKeyWindow && !viewerReturned && app.luaEditor(for: file) == nil,
            "Lua viewer accepted F6 without VF_ENABLE_F6.")
        viewWindow.performClose(nil)
        let viewed = try await view.value
        let missing = try await run("return viewer.Viewer([=[\(newPath)]=], nil,nil,nil,nil,nil, F.VF_NONMODAL+F.VF_IMMEDIATERETURN)")
        try require(viewed == [.bool(true)] && missing == [.bool(false)], "Lua viewer did not report the actual open result.")

        do {
            _ = try await call("viewer.Viewer", [.string(path), .nilValue, .nilValue, .nilValue, .nilValue, .nilValue,
                .string("VF_DELETEONLYFILEONCLOSE")], app: app)
            throw ExtensionAPIError("Lua viewer silently accepted an unsupported deletion flag.")
        } catch let error as ExtensionAPIError {
            let bytes = try Data(contentsOf: file)
            try require(error.localizedDescription.contains("удаления") && bytes == saved,
                "Lua viewer deletion flag did not fail explicitly before touching the file.")
        }

        let switchFile = directory.appendingPathComponent("switch.txt")
        let switchPath = switchFile.path
        try original.write(to: switchFile)
        var modalSwitchReturned = false
        let modalSwitch = Task { @MainActor in
            defer { modalSwitchReturned = true }
            return try await run("return viewer.Viewer([=[\(switchPath)]=], 'Lua F6 modal', nil,nil,nil,nil, F.VF_ENABLE_F6,1251)")
        }
        defer { modalSwitch.cancel() }
        try await waitUntil { modalSwitchReturned || NSApp.modalWindow?.windowController is ViewerWindow }
        guard !modalSwitchReturned, let modalViewer = NSApp.modalWindow?.windowController as? ViewerWindow,
              modalViewer.sourceFileURL == switchFile, let modalViewerWindow = modalViewer.window else {
            throw ExtensionAPIError("Lua F6 fixture could not open the modal viewer.")
        }
        defer { modalViewerWindow.close() }
        let viewerPosition = try await modalViewer.luaViewerCall("viewer.SetPosition", [.nilValue, .integer(4)])
        try require(viewerPosition == [.integer(4)], "Lua F6 fixture could not set the viewer byte position.")
        try await sendF6(modalViewerWindow)
        try await waitUntil { modalSwitchReturned }
        let modalResult = try await modalSwitch.value
        guard let f6Editor = app.luaEditor(for: switchFile), let f6EditorWindow = f6Editor.window else {
            throw ExtensionAPIError("F6 did not open the real editor from a Lua viewer.")
        }
        defer { f6Editor.closeArchiveWorkingCopyWithoutSaving() }
        let f6Position = try f6Editor.luaEditorCall("editor.GetInfo", []).lua(0).hostTable
        try require(modalResult == [.bool(false)] && modalViewer.luaDocumentIsClosed && f6EditorWindow.isKeyWindow &&
                    f6Position["CurLine"] == .integer(2) && f6Position["CurPos"] == .integer(2) &&
                    f6Position["CurTabPos"] == .integer(5) && f6Position["CodePage"] == .integer(1251),
            "F6 did not preserve the viewer position, code page, editor focus or modal false result.")
        f6EditorWindow.performClose(nil)

        let f6Edit = try await run("return editor.Editor([=[\(switchPath)]=], 'Lua F6 editor', nil,nil,nil,nil, 'EF_NONMODAL EF_IMMEDIATERETURN EF_ENABLE_F6',2,6,1251)")
        guard f6Edit == [.integer(1)], let sourceEditor = app.luaEditor(for: switchFile),
              let sourceEditorWindow = sourceEditor.window else { throw ExtensionAPIError("Lua F6 fixture could not open the editor.") }
        defer { sourceEditor.closeArchiveWorkingCopyWithoutSaving() }
        try await sendF6(sourceEditorWindow)
        try await waitUntil { (NSApp.keyWindow?.windowController as? ViewerWindow)?.sourceFileURL == switchFile }
        guard let f6Viewer = NSApp.keyWindow?.windowController as? ViewerWindow, let f6ViewerWindow = f6Viewer.window else {
            throw ExtensionAPIError("F6 did not focus the real viewer from a Lua editor.")
        }
        defer { f6ViewerWindow.close() }
        let f6ViewInfo = try await f6Viewer.luaViewerCall("viewer.GetInfo", []).lua(0).hostTable
        try require(sourceEditor.luaDocumentIsClosed && f6ViewerWindow.isKeyWindow && f6ViewInfo["FilePos"] == .integer(5) &&
                    f6ViewInfo["CurMode"]?.hostTable["CodePage"] == .integer(1251),
            "F6 did not preserve the editor position, code page or viewer focus.")
        f6ViewerWindow.performClose(nil)
        return ["Lua document opens wait for native close and handle cancellation",
                "Lua editor opening title, visual caret, code page, save result, lock and new-file behavior",
                "Lua viewer open result, title, code page and rejected deletion flags",
                "Lua document F6 flags, position and focus handoff, and modal viewer exit result"]
    }
}
