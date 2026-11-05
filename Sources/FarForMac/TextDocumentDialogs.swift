import AppKit
import FarCore

struct EditorOpenCreateRequest {
    let url: URL
    let encoding: ViewerEncoding
    let useRememberedEncoding: Bool
}

@MainActor
enum TextDocumentDialogs {
    static func bookmarkShortcut(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> (slot: Int, set: Bool)? {
        let digits: [UInt16: Int] = [29: 0, 18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
        guard flags == .control || flags == [.control, .shift], let slot = digits[event.keyCode] else { return nil }
        let rightControl = event.modifierFlags.rawValue & 0x00002000 != 0 // NX_DEVICERCTLKEYMASK
        return (slot, rightControl || flags.contains(.shift))
    }

    static var systemCodePages: [ViewerEncoding] {
        Locale.current.language.languageCode?.identifier == "ru" ? [.windows1251, .dos866] : [.windows1252, .dos437]
    }

    static func nextCodePage(after encoding: ViewerEncoding) -> ViewerEncoding {
        let pages = systemCodePages
        return encoding == pages[0] ? pages[1] : pages[0]
    }

    static func codePage(current: ViewerEncoding) -> ViewerEncoding? {
        let popup = codePageList(current: current)
        popup.frame = NSRect(x: 0, y: 0, width: 330, height: 28)
        let alert = NSAlert()
        alert.messageText = "Кодовые страницы"
        alert.accessoryView = popup
        alert.addButton(withTitle: "Выбрать")
        alert.addButton(withTitle: "Отмена")
        return alert.runModal() == .alertFirstButtonReturn ? selectedCodePage(in: popup) : nil
    }

    static func openCreate(in directory: URL) -> EditorOpenCreateRequest? {
        let path = NSTextField(string: "")
        path.placeholderString = "Имя или путь к файлу"
        path.widthAnchor.constraint(equalToConstant: 390).isActive = true
        path.setAccessibilityLabel("Имя файла")
        let popup = codePageList(current: nil, includeDefault: true)
        let controls = accessory([path, NSStackView(views: [NSTextField(labelWithString: "Кодовая страница"), popup])], height: 64)
        let alert = NSAlert()
        alert.messageText = "Открыть или создать файл"
        alert.informativeText = directory.path
        alert.accessoryView = controls
        alert.addButton(withTitle: "Открыть / создать")
        alert.addButton(withTitle: "Отмена")
        alert.window.initialFirstResponder = path
        while alert.runModal() == .alertFirstButtonReturn {
            if !path.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !path.stringValue.contains("\0") {
                let expanded = (path.stringValue as NSString).expandingTildeInPath
                let base = URL(fileURLWithPath: directory.path, isDirectory: true)
                let url = URL(fileURLWithPath: expanded, relativeTo: base).standardizedFileURL
                return EditorOpenCreateRequest(url: url, encoding: selectedCodePage(in: popup) ?? .automatic,
                                               useRememberedEncoding: popup.indexOfSelectedItem == 0)
            }
            alert.informativeText = "Введите имя файла. Относительный путь считается от \(directory.path)."
        }
        return nil
    }

    static func accessory(_ views: [NSView], height: CGFloat, width: CGFloat = 405) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: width, height: height)
        return stack
    }

    private static func selectedCodePage(in popup: NSPopUpButton) -> ViewerEncoding? {
        (popup.selectedItem?.representedObject as? String).flatMap(ViewerEncoding.init(rawValue:))
    }

    private static func codePageList(current: ViewerEncoding?, includeDefault: Bool = false) -> NSPopUpButton {
        let popup = NSPopUpButton()
        popup.menu?.autoenablesItems = false
        if includeDefault { popup.addItem(withTitle: "По умолчанию") }
        func add(_ value: ViewerEncoding) {
            popup.addItem(withTitle: value.title)
            popup.lastItem?.representedObject = value.rawValue
            if value == current { popup.select(popup.lastItem) }
        }
        func group(_ name: String, _ values: [ViewerEncoding]) {
            popup.addItem(withTitle: name)
            popup.lastItem?.isEnabled = false
            values.forEach(add)
        }
        add(.automatic)
        group("Системные (ANSI / OEM)", systemCodePages)
        let unicode: [ViewerEncoding] = [.utf8, .utf16LE, .utf16BE]
        group("Unicode", unicode)
        group("Другие", ViewerEncoding.allCases.filter { $0 != .automatic && !systemCodePages.contains($0) && !unicode.contains($0) })
        return popup
    }
}
