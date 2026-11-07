import AppKit
import FarCore

/// Dialog fields and key capture follow far/macro.cpp AssignMacroKey/GetMacroSettings.
@MainActor enum FarLuaRecordingDialog {
    struct Settings { let sequence: String; let description: String; let flags: String }
    static func key() -> String? {
        let key = NSComboBox(frame: NSRect(x:0, y:0, width:360, height:26))
        key.addItems(withObjectValues: ["Enter", "NumEnter", "Esc", "F1", "CtrlDown", "CtrlF5"])
        key.isEditable = true
        let alert = NSAlert(); alert.messageText = "Назначение макроса"; alert.informativeText = "Нажмите нужную клавишу"
        alert.accessoryView = key; alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Отмена")
        alert.window.initialFirstResponder = key
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === alert.window else { return event }
            if event.keyCode == 53 { return event }
            if [36, 76].contains(event.keyCode), !key.stringValue.isEmpty { return event }
            if let name = FarLuaKeys.name(event) { key.stringValue = name; return nil }
            return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        guard alert.runModal() == .alertFirstButtonReturn, !key.stringValue.isEmpty else { return nil }
        return key.stringValue
    }
    static func settings(key: String, sequence: String) -> Settings? {
        let script = NSTextView(frame: NSRect(x:0,y:0,width:560,height:100)); script.string = sequence
        script.font = .monospacedSystemFont(ofSize:12,weight:.regular); script.isRichText = false
        let scroll = NSScrollView(frame:script.frame); scroll.documentView = script; scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(equalToConstant:100).isActive = true
        let description = NSTextField(string: "")
        let afterStart = NSButton(checkboxWithTitle:"Выполнять после запуска FAR",target:nil,action:nil)
        func tri(_ title: String) -> NSButton {
            let button = NSButton(checkboxWithTitle:title,target:nil,action:nil); button.allowsMixedState = true; button.state = .mixed; return button
        }
        let groups: [(String,String,String)] = [
            ("Активная: панель плагина","NoFilePanels","NoPluginPanels"),
            ("Активная: папка под курсором","NoFiles","NoFolders"),
            ("Активная: есть пометки","Selection","NoSelection"),
            ("Пассивная: панель плагина","NoFilePPanels","NoPluginPPanels"),
            ("Пассивная: папка под курсором","NoPFiles","NoPFolders"),
            ("Пассивная: есть пометки","PSelection","NoPSelection"),
            ("Пустая командная строка","EmptyCommandLine","NotEmptyCommandLine"),
            ("Есть выделенный блок","EVSelection","NoEVSelection")]
        let controls = groups.map { tri($0.0) }
        let stack = NSStackView(views:[NSTextField(labelWithString:"Последовательность:"),scroll,NSTextField(labelWithString:"Описание:"),description,afterStart] + controls)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        stack.frame = NSRect(x:0,y:0,width:560,height:420)
        description.widthAnchor.constraint(equalToConstant:560).isActive = true
        scroll.widthAnchor.constraint(equalToConstant:560).isActive = true
        let alert = NSAlert(); alert.messageText = "Параметры макроса для '\(key)'"; alert.accessoryView = stack
        alert.addButton(withTitle:"OK"); alert.addButton(withTitle:"Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        var flags = afterStart.state == .on ? ["RunAfterFARStart"] : []
        for (index, control) in controls.enumerated() where control.state != .mixed { flags.append(control.state == .on ? groups[index].1 : groups[index].2) }
        return Settings(sequence:script.string,description:description.stringValue,flags:flags.joined(separator:" "))
    }
}
