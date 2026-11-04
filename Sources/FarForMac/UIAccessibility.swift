import AppKit
import ObjectiveC

@MainActor
enum UIPreferences {
    static var fontScale: CGFloat {
        get {
            let value = AppPreferences.defaults.double(forKey: "ui.fontScale")
            return value.isFinite && value > 0 ? min(1.5, max(0.85, value)) : 1
        }
        set { AppPreferences.defaults.set(Double(min(1.5, max(0.85, newValue))), forKey: "ui.fontScale") }
    }
    static var highContrast: Bool {
        get { AppPreferences.defaults.bool(forKey: "ui.highContrast") }
        set { AppPreferences.defaults.set(newValue, forKey: "ui.highContrast") }
    }
    static func fontSize(_ base: CGFloat) -> CGFloat { base * fontScale }
    static func color(_ normal: NSColor, contrast: NSColor) -> NSColor { highContrast ? contrast : normal }
}

private var accessibilityColorsKey: UInt8 = 0
private var accessibilityCopyKey: UInt8 = 0
private var accessibilityBaseFontKey: UInt8 = 0
private var accessibilityBaseRowHeightKey: UInt8 = 0

@MainActor
enum UIAccessibility {
    private static func localized(_ object: NSObject, key: String, value: String) -> String {
        var copies = objc_getAssociatedObject(object, &accessibilityCopyKey) as? [String: [String]] ?? [:]
        let previous = copies[key]
        let original = previous?.last == value ? previous![0] : value
        let translated = L10n.text(original)
        copies[key] = [original, translated]
        objc_setAssociatedObject(object, &accessibilityCopyKey, copies, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return translated
    }

    private static func contrastColor(_ object: NSObject, key: String, original: NSColor, contrast: NSColor) -> NSColor {
        var colors = objc_getAssociatedObject(object, &accessibilityColorsKey) as? [String: NSColor] ?? [:]
        if colors[key] == nil { colors[key] = original }
        objc_setAssociatedObject(object, &accessibilityColorsKey, colors, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return UIPreferences.highContrast ? contrast : colors[key]!
    }

    static func apply(menu: NSMenu) {
        menu.title = localized(menu, key: "title", value: menu.title)
        for item in menu.items {
            item.title = localized(item, key: "title", value: item.title)
            if let submenu = item.submenu { apply(menu: submenu) }
        }
    }

    /// Does not change editable fields, user content, identifiers, actions or key equivalents.
    /// Base fonts are retained, making repeated applications safe.
    static func apply(to view: NSView) {
        // Image buttons may carry AppKit's invisible default title ("Button").
        // Setting it, even to the same value, can expose it beside the image.
        if let button = view as? NSButton, button.imagePosition == .imageOnly { return }
        if let popup = view as? NSPopUpButton {
            if let menu = popup.menu { apply(menu: menu) }
        } else if let button = view as? NSButton {
            let translated = localized(button, key: "title", value: button.title)
            if translated != button.title { button.title = translated }
        }
        if let field = view as? NSTextField {
            if !field.isEditable && field.identifier?.rawValue == "localized-label" && !isTableContent(field) { field.stringValue = localized(field, key: "value", value: field.stringValue) }
            if let placeholder = field.placeholderString { field.placeholderString = localized(field, key: "placeholder", value: placeholder) }
        }
        if let field = view as? NSTextField {
            field.textColor = contrastColor(field, key: "text", original: field.textColor ?? .labelColor, contrast: .white)
            if field.drawsBackground { field.backgroundColor = contrastColor(field, key: "background", original: field.backgroundColor ?? .textBackgroundColor, contrast: .black) }
        }
        if let text = view as? NSTextView {
            if let font = text.font {
                let base = objc_getAssociatedObject(text, &accessibilityBaseFontKey) as? NSFont ?? font
                objc_setAssociatedObject(text, &accessibilityBaseFontKey, base, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                text.font = NSFontManager.shared.convert(base, toSize: base.pointSize * UIPreferences.fontScale)
            }
            text.textColor = contrastColor(text, key: "text", original: text.textColor ?? .textColor, contrast: .white)
            text.insertionPointColor = contrastColor(text, key: "caret", original: text.insertionPointColor, contrast: .white)
            text.backgroundColor = contrastColor(text, key: "background", original: text.backgroundColor, contrast: .black)
        }
        if let scroll = view as? NSScrollView {
            scroll.backgroundColor = contrastColor(scroll, key: "background", original: scroll.backgroundColor, contrast: .black)
        }
        if let table = view as? NSTableView {
            table.backgroundColor = contrastColor(table, key: "background", original: table.backgroundColor, contrast: .black)
        }
        if let control = view as? NSControl, let font = control.font {
            let base = objc_getAssociatedObject(control, &accessibilityBaseFontKey) as? NSFont ?? font
            objc_setAssociatedObject(control, &accessibilityBaseFontKey, base, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            control.font = NSFontManager.shared.convert(base, toSize: base.pointSize * UIPreferences.fontScale)
        }
        if let table = view as? NSTableView {
            let base = objc_getAssociatedObject(table, &accessibilityBaseRowHeightKey) as? NSNumber ?? NSNumber(value: Double(table.rowHeight))
            objc_setAssociatedObject(table, &accessibilityBaseRowHeightKey, base, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            table.rowHeight = CGFloat(base.doubleValue) * UIPreferences.fontScale
            for column in table.tableColumns { column.title = localized(column, key: "title", value: column.title) }
        }
        // Composite controls own private image/text buttons. In particular, touching
        // NSSearchField's search/cancel buttons can reveal their hidden titles.
        // AppKit retains responsibility for the internals of standard controls.
        if view is NSControl && !(view is NSTableView) { return }
        for child in view.subviews { apply(to: child) }
    }

    private static func isTableContent(_ view: NSView) -> Bool {
        var ancestor = view.superview
        while let current = ancestor {
            if current is NSTableView { return true }
            ancestor = current.superview
        }
        return false
    }

    static func panelName(_ key: String) -> String { L10n.text(key == "left" ? "Левая панель" : "Правая панель") }
    static func fileRow(name: String, isDirectory: Bool, isMarked: Bool, isSymbolicLink: Bool = false) -> String {
        let kind = isSymbolicLink ? "Символическая ссылка" : (isDirectory ? "Папка" : "Файл")
        return [name, L10n.text(kind), L10n.text(isMarked ? "Помечено" : "Не помечено")].joined(separator: ", ")
    }
}

@MainActor
final class UIPreferencesWindow: NSWindowController {
    private let language = NSPopUpButton()
    private let scale = NSSlider(value: Double(UIPreferences.fontScale), minValue: 0.85, maxValue: 1.5, target: nil, action: nil)
    private let contrast = NSButton(checkboxWithTitle: L10n.text("Повышенный контраст"), target: nil, action: nil)
    private let onApply: () -> Void

    init(onApply: @escaping () -> Void) {
        self.onApply = onApply
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 220), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = L10n.text("Доступность и язык")
        window.isReleasedWhenClosed = false
        language.addItems(withTitles: ["Русский", "English"])
        language.selectItem(at: L10n.language == .russian ? 0 : 1)
        language.setAccessibilityLabel(L10n.text("Язык"))
        scale.setAccessibilityLabel(L10n.text("Размер текста"))
        scale.setAccessibilityHelp("85%–150%")
        contrast.state = UIPreferences.highContrast ? .on : .off
        let apply = NSButton(title: L10n.text("Применить"), target: self, action: #selector(save))
        apply.keyEquivalent = "\r"; apply.bezelStyle = .rounded
        let cancel = NSButton(title: L10n.text("Отмена"), target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"; cancel.bezelStyle = .rounded
        let stack = NSStackView(views: [horizontal([label(L10n.text("Язык")), language]), horizontal([label(L10n.text("Размер текста")), scale]), contrast, horizontal([NSView(), cancel, apply])])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        window.contentView = inset(stack, x: 20, y: 20)
        window.initialFirstResponder = language
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func cancel() { close() }
    @objc private func save() {
        L10n.language = language.indexOfSelectedItem == 0 ? .russian : .english
        UIPreferences.fontScale = CGFloat(scale.doubleValue)
        UIPreferences.highContrast = contrast.state == .on
        onApply()
        close()
    }
}
