import AppKit
import FarCore

@MainActor
enum BracketsWorkspace {
    private static let key = "plugins.brackets.options.v1"
    static var options: EditorBrackets.Options {
        get {
            guard let data = AppPreferences.defaults.data(forKey: key),
                  let value = try? JSONDecoder().decode(EditorBrackets.Options.self, from: data), value.isValid else { return .init() }
            return value
        }
        set { if newValue.isValid, let data = try? JSONEncoder().encode(newValue) { AppPreferences.defaults.set(data, forKey: key) } }
    }

    static func show(for editor: TextFileWindow) {
        while true {
            let menu = PanelListMenu(title: "Парные скобки", hint: "Enter — выполнить · Esc — отмена")
            menu.replaceRows([.init(title: "Найти"), .init(title: "Выделить"), .init(title: "Настройка…")])
            var selected: Int?
            menu.onActivate = { selected = $0; menu.dismiss() }
            defer { menu.onActivate = nil }
            menu.run(relativeTo: editor.window)
            if selected == 2 { configure(owner: editor.window); continue }
            if let selected { editor.performBrackets(select: selected == 1, direction: nil) }
            return
        }
    }

    static func direction(owner: NSWindow?) -> EditorBrackets.Direction? {
        while true {
            let menu = PanelListMenu(title: "Парные скобки — направление", hint: "Enter — выбрать · Esc — отмена")
            menu.replaceRows([.init(title: "Вперёд"), .init(title: "Назад"), .init(title: "Настройка…")])
            var selected: Int?
            menu.onActivate = { selected = $0; menu.dismiss() }
            defer { menu.onActivate = nil }
            menu.run(relativeTo: owner)
            if selected == 2 { configure(owner: owner); continue }
            guard let selected else { return nil }
            return selected == 0 ? .forward : .backward
        }
    }

    static func configure(owner: NSWindow?) {
        let original = options
        let quoted = NSButton(checkboxWithTitle: "Игнорировать скобки в кавычках", target: nil, action: nil)
        let after = NSButton(checkboxWithTitle: "Игнорировать поведение «за скобкой»", target: nil, action: nil)
        let priority = NSButton(checkboxWithTitle: "Первыми рассматриваются двойные скобки", target: nil, action: nil)
        let beep = NSButton(checkboxWithTitle: "Звуковой сигнал", target: nil, action: nil)
        for (control, value) in [(quoted, original.ignoreQuoted), (after, original.ignoreAfter), (priority, original.doubleFirst), (beep, original.beep)] {
            control.state = value ? .on : .off
        }
        let quotes = NSTextField(string: original.quotes)
        let singles = NSTextField(string: original.singles)
        let doubles = NSTextField(string: original.doubles)
        let stack = NSStackView(views: [quoted, after, priority, beep,
            NSTextField(labelWithString: "Типы кавычек (по 2 символа):"), quotes,
            NSTextField(labelWithString: "Одинарные парные скобки (по 2 символа):"), singles,
            NSTextField(labelWithString: "Двойные парные скобки (по 4 символа):"), doubles])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        stack.setFrameSize(NSSize(width: 490, height: 290))
        for field in [quotes, singles, doubles] { field.widthAnchor.constraint(equalToConstant: 480).isActive = true }
        let alert = NSAlert(); alert.messageText = "Парные скобки — настройка"
        alert.informativeText = "До 10 пар в каждом описании."
        alert.accessoryView = stack; alert.addButton(withTitle: "Сохранить"); alert.addButton(withTitle: "Отмена")
        defer { owner?.makeKeyAndOrderFront(nil) }
        while alert.runModal() == .alertFirstButtonReturn {
            var value = original
            value.ignoreQuoted = quoted.state == .on; value.ignoreAfter = after.state == .on
            value.doubleFirst = priority.state == .on; value.beep = beep.state == .on
            value.quotes = quotes.stringValue; value.singles = singles.stringValue; value.doubles = doubles.stringValue
            guard value.isValid else { alert.informativeText = "Проверьте число символов: пары по 2 или 4, не более 10 пар; без переводов строк и emoji."; continue }
            options = value; return
        }
    }
}
