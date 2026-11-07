import AppKit
import Darwin
import FarCore

/// Independent tool windows retain themselves until closed; all filesystem work
/// runs away from the main thread. Callers only need to showWindow(nil).
@MainActor
class FileToolsWindowController: NSWindowController, NSWindowDelegate {
    let status = NSTextField(wrappingLabelWithString: "")
    var isWorking = false
    var hasPendingMutation = false
    private var retainedWhileOpen: FileToolsWindowController?

    init(title: String, width: CGFloat = 680, height: CGFloat = 450) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = title
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 300)
        window.center()
        window.delegate = self
        status.textColor = .secondaryLabelColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func showWindow(_ sender: Any?) {
        retainedWhileOpen = self
        super.showWindow(sender)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if hasPendingMutation { status.stringValue = "Дождитесь завершения файловой операции."; NSSound.beep(); return false }
        return true
    }
    func windowWillClose(_ notification: Notification) { retainedWhileOpen = nil }
    func content(_ views: [NSView]) {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        let container = NSView()
        container.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18)
        ])
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        window?.contentView = container
    }
    func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }
    func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views); row.orientation = .horizontal; row.spacing = 10
        return row
    }
    func worker<T>(_ work: @escaping () throws -> T, completion: @escaping (Result<T, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result(catching: work)
            DispatchQueue.main.async { completion(result) }
        }
    }
}

@MainActor
final class BatchRenameWindow: FileToolsWindowController, NSTextFieldDelegate {
    private let urls: [URL]
    private let onComplete: () -> Void
    private let canMutate: () -> Bool
    private let template = NSTextField(string: "{name}_{n}.{ext}")
    private let modePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let help = NSTextField(wrappingLabelWithString: "")
    private let preview = NSTextView()
    private var plan: [BatchRenameEntry] = []
    private var reviewedTemplate = ""
    private var reviewedMode = BatchRenameMode.template
    private var previewRevision = 0
    private var selectedMode: BatchRenameMode { modePicker.indexOfSelectedItem == 1 ? .farMask : .template }
    private lazy var previewButton = button(metadataText("Предпросмотр", "Preview"), #selector(makePreview))
    private lazy var applyButton = button(metadataText("Переименовать по предпросмотру", "Apply reviewed renames"), #selector(applyRename))

    init(urls: [URL], canMutate: @escaping () -> Bool = { true }, onComplete: @escaping () -> Void) {
        self.urls = urls; self.onComplete = onComplete; self.canMutate = canMutate
        super.init(title: metadataText("Групповое переименование", "Batch rename"), height: 490)
        template.delegate = self
        modePicker.addItems(withTitles: [metadataText("Шаблон {name}/{ext}/{n}", "Template {name}/{ext}/{n}"), metadataText("Маска имени FAR (* и ?)", "FAR filename mask (* and ?)")])
        modePicker.target = self; modePicker.action = #selector(changeRenameMode)
        modePicker.setAccessibilityLabel(metadataText("Режим переименования", "Rename mode"))
        template.setAccessibilityLabel(metadataText("Шаблон или маска нового имени", "New filename template or mask"))
        updateHelp()
        preview.isEditable = false; preview.isRichText = false
        preview.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        preview.isVerticallyResizable = true; preview.autoresizingMask = [.width]
        preview.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(); scroll.documentView = preview; scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        applyButton.isEnabled = false
        status.stringValue = metadataText("Выбрано: \(urls.count). Сначала проверьте новые имена. Перезапись и циклы запрещены.", "Selected: \(urls.count). Review new names first. Overwrites and cycles are rejected.")
        content([modePicker, help, template, row([previewButton, applyButton]), scroll, status])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func controlTextDidChange(_ obj: Notification) {
        invalidatePreview()
    }
    private func invalidatePreview() {
        previewRevision += 1
        plan = []; applyButton.isEnabled = false; preview.string = ""
        status.stringValue = metadataText("Шаблон или режим изменён. Создайте новый предпросмотр.", "Pattern or mode changed. Create a new preview.")
    }
    @objc private func changeRenameMode() {
        template.stringValue = selectedMode == .farMask ? "*.bak" : "{name}_{n}.{ext}"
        updateHelp(); invalidatePreview()
    }
    private func updateHelp() {
        help.stringValue = selectedMode == .farMask ? metadataText(
            "Маска FAR: *.bak заменяет последнее расширение; *?.bak добавляет .bak к полному имени. ? копирует позицию, кроме точки; обычный символ заменяет позицию. Точка пропускает исходное имя до следующей точки. Скобки и {name} буквальны. Только имя, без пути. Unicode вне BMP занимает две позиции ?.",
            "FAR mask: *.bak replaces the last extension; *?.bak appends .bak to the full name. ? copies a position except a dot; a literal replaces a position. A dot skips through the next source dot. Brackets and {name} are literal. Filename only, without a path. Non-BMP Unicode uses two ? positions.") : metadataText(
            "Шаблон: {name} — имя без расширения, {ext} — расширение без точки, {n} — номер с 1. Точка вводится явно. Для папок {ext} пусто. Пример: {name}_{n}.{ext}",
            "Template: {name} is the stem, {ext} the extension without a dot, {n} the index from 1. Enter dots explicitly. Directories have an empty {ext}. Example: {name}_{n}.{ext}")
    }
    @objc private func makePreview() {
        let value = template.stringValue
        let mode = selectedMode, revision = previewRevision
        isWorking = true
        previewButton.isEnabled = false; applyButton.isEnabled = false
        status.stringValue = metadataText("Проверка имён…", "Checking names…")
        worker({ try FileTools.renamePlan(self.urls, template: value, mode: mode) }) { [self] result in
            isWorking = false
            previewButton.isEnabled = true
            guard revision == previewRevision, value == template.stringValue, mode == selectedMode else { return }
            switch result {
            case .success(let entries):
                plan = entries; reviewedTemplate = value; reviewedMode = mode
                preview.string = (modePicker.titleOfSelectedItem ?? "") + "\n" + entries.map { "\($0.source.url.lastPathComponent)  →  \($0.destination.lastPathComponent)" }.joined(separator: "\n")
                applyButton.isEnabled = true
                status.stringValue = metadataText("Проверьте каждую строку. Будет переименовано объектов: \(entries.count).", "Review each row. Items to rename: \(entries.count).")
            case .failure(let error): plan = []; status.stringValue = error.localizedDescription
            }
        }
    }
    @objc private func applyRename() {
        guard !plan.isEmpty, reviewedTemplate == template.stringValue, reviewedMode == selectedMode else { return }
        guard canMutate() else { status.stringValue = metadataText("Другая файловая операция ещё выполняется.", "Another file operation is still running."); return }
        isWorking = true; hasPendingMutation = true
        let entries = plan
        let propagateDescriptions = DescriptionPreferences.enabled
        let descriptionEncodings = DescriptionPreferences.encodings
        applyButton.isEnabled = false; previewButton.isEnabled = false; template.isEnabled = false; modePicker.isEnabled = false
        status.stringValue = metadataText("Переименование…", "Renaming…")
        worker({ try FileTools.executeRename(entries, propagateDescriptions: propagateDescriptions, descriptionEncodings: descriptionEncodings) }) { [self] result in
            isWorking = false; hasPendingMutation = false
            onComplete() // refresh even after a partial failure
            template.isEnabled = true; modePicker.isEnabled = true; previewButton.isEnabled = true; plan = []
            switch result {
            case .success(let count): status.stringValue = metadataText("Переименовано: \(count).", "Renamed: \(count)."); preview.string = ""
            case .failure(let error): status.stringValue = error.localizedDescription
            }
        }
    }

    static func verifyFARRenameUI() async throws -> [String] {
        guard AppRuntime.isSmoke, let directory = AppRuntime.smokeStateDirectory else { throw ExtensionAPIError("Rename smoke requires isolated state.") }
        let root = directory.appendingPathComponent("rename-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("отчёт.part.txt")
        try Data("preserved bytes".utf8).write(to: source)
        let controller = BatchRenameWindow(urls: [source], onComplete: {})
        controller.showWindow(nil); defer { controller.close() }
        func waitForPreview() async throws {
            for _ in 0..<1000 {
                if !controller.isWorking { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw ExtensionAPIError("Rename smoke timed out.")
        }
        controller.modePicker.selectItem(at: 1); controller.changeRenameMode(); controller.makePreview()
        try await waitForPreview()
        guard controller.applyButton.isEnabled, controller.plan.first?.destination.lastPathComponent == "отчёт.part.bak",
              controller.preview.string.contains("FAR"), FileManager.default.fileExists(atPath: source.path) else {
            throw ExtensionAPIError("FAR rename preview did not preserve the source or mode.")
        }
        controller.modePicker.selectItem(at: 0); controller.changeRenameMode()
        guard controller.plan.isEmpty, !controller.applyButton.isEnabled else { throw ExtensionAPIError("Rename mode change retained a stale plan.") }
        controller.modePicker.selectItem(at: 1); controller.changeRenameMode(); controller.makePreview()
        try await waitForPreview(); controller.applyRename(); try await waitForPreview()
        let destination = root.appendingPathComponent("отчёт.part.bak")
        guard !FileManager.default.fileExists(atPath: source.path),
              try String(contentsOf: destination, encoding: .utf8) == "preserved bytes", controller.plan.isEmpty else {
            throw ExtensionAPIError("FAR rename apply did not preserve content.")
        }
        return ["FAR destination masks preview without mutation and invalidate on mode change", "FAR rename asynchronous apply preserves file bytes"]
    }
}

@MainActor
final class FilePropertiesWindow: FileToolsWindowController {
    private let url: URL
    private let onComplete: () -> Void
    private let canMutate: () -> Bool
    private let details = NSTextField(wrappingLabelWithString: "Загрузка…")
    private let permissions = NSTextField(string: "")
    private let changePermissions = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let changeAccessed = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let changeModified = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let changeCreated = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let accessed = NSDatePicker()
    private let modified = NSDatePicker()
    private let created = NSDatePicker()
    private let hiddenFlag = NSPopUpButton(frame: .zero, pullsDown: false)
    private let noDumpFlag = NSPopUpButton(frame: .zero, pullsDown: false)
    private let ownership = NSTextField(wrappingLabelWithString: "")
    private let changeOwner = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let ownerID = NSTextField(string: "")
    private let changeGroup = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let groupPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private var groups: [MetadataGroup] = []
    private var ownershipSnapshot: MetadataOwnershipSnapshot?
    private let recursive = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let preview = NSTextView()
    private var plan: MetadataMutationPlan?
    private var cancellation: FileToolCancellation?
    private var source: FileToolItem?
    private var pendingACL: String?
    private lazy var aclButton = button(metadataText("ACL…", "ACL…"), #selector(editACL))
    private let aclStatus = NSTextField(labelWithString: "")
    private lazy var previewButton = button(metadataText("Предпросмотр изменений", "Preview changes"), #selector(makePreview))
    private lazy var saveButton = button(metadataText("Применить по предпросмотру…", "Apply reviewed changes…"), #selector(savePermissions))
    private lazy var cancelButton = button(L10n.text("Отмена"), #selector(cancelWork))

    init(url: URL, canMutate: @escaping () -> Bool = { true }, onComplete: @escaping () -> Void) {
        self.url = url; self.onComplete = onComplete; self.canMutate = canMutate
        super.init(title: metadataText("Свойства — ", "Properties — ") + url.lastPathComponent, width: 840, height: 820)
        window?.minSize = NSSize(width: 800, height: 790)
        details.isSelectable = true
        permissions.placeholderString = "0755"
        changePermissions.title = metadataText("Изменить POSIX-права (000–7777):", "Change POSIX permissions (000–7777):")
        changeAccessed.title = metadataText("Изменить дату доступа:", "Change access date:")
        changeModified.title = metadataText("Изменить дату изменения:", "Change modification date:")
        changeCreated.title = metadataText("Изменить дату создания:", "Change creation date:")
        changeGroup.title = metadataText("Изменить группу:", "Change group:")
        changeOwner.title = metadataText("Изменить UID:", "Change UID:")
        ownerID.setAccessibilityLabel(metadataText("Номер нового владельца", "New owner ID"))
        ownerID.widthAnchor.constraint(equalToConstant: 96).isActive = true
        ownership.isSelectable = true
        groupPicker.setAccessibilityLabel(metadataText("Группа текущего пользователя", "Current user group"))
        groupPicker.target = self; groupPicker.action = #selector(invalidatePreview)
        recursive.title = metadataText("Все выбранные изменения для вложенных файлов и папок", "Apply all selected changes to nested files and folders")
        for picker in [accessed, modified, created] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
            picker.locale = .current; picker.timeZone = .current
        }
        accessed.setAccessibilityLabel(metadataText("Дата доступа, местное время", "Access date, local time"))
        modified.setAccessibilityLabel(metadataText("Дата изменения, местное время", "Modification date, local time"))
        created.setAccessibilityLabel(metadataText("Дата создания, местное время", "Creation date, local time"))
        permissions.setAccessibilityLabel(metadataText("POSIX-права в восьмеричной форме", "Octal POSIX permissions"))
        for control in [changePermissions, changeAccessed, changeModified, changeCreated, changeGroup, changeOwner, recursive,
                        accessed, modified, created, hiddenFlag, noDumpFlag] as [NSControl] {
            control.target = self; control.action = #selector(invalidatePreview)
        }
        for field in [permissions, ownerID] {
            NotificationCenter.default.addObserver(self, selector: #selector(invalidatePreview), name: NSControl.textDidChangeNotification, object: field)
        }
        for (picker, name) in [(hiddenFlag, metadataText("Скрытый", "Hidden")), (noDumpFlag, "NoDump")] {
            picker.addItems(withTitles: [metadataText("Оставить", "Keep"), metadataText("Установить", "Set"), metadataText("Снять", "Clear")])
            picker.setAccessibilityLabel(name)
        }
        preview.isEditable = false; preview.isRichText = false; preview.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        preview.isVerticallyResizable = true; preview.autoresizingMask = [.width]; preview.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(); scroll.documentView = preview; scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 145).isActive = true
        let note = NSTextField(wrappingLabelWithString: metadataText("Даты в местном времени. Ссылки, специальные файлы и другие тома пропускаются. Метаданные общие для всех жёстких ссылок. Смена UID доступна с правами root. Смена UID/GID может снять set-ID биты. ACL применяется к одному объекту.", "Dates use local time. Links, special files and other volumes are skipped. Metadata affects all hard links. Changing UID requires root. Changing UID/GID may clear set-ID bits. ACLs apply to one item."))
        saveButton.isEnabled = false; previewButton.isEnabled = false; cancelButton.isEnabled = false
        content([details, ownership, row([changeGroup, groupPicker, changeOwner, ownerID]), row([changePermissions, permissions]),
                 row([changeAccessed, accessed]), row([changeModified, modified]), row([changeCreated, created]),
                 row([label(metadataText("Скрытый", "Hidden"), size: 12), hiddenFlag, label("NoDump", size: 12), noDumpFlag, aclButton, aclStatus]),
                 recursive, note, row([previewButton, saveButton, cancelButton]), scroll, status])
        setControlsEnabled(false)
        load()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func load(summary: String? = nil) {
        worker({ (try FileTools.metadata(self.url), try MetadataOwnership.snapshot(url: self.url), try MetadataOwnership.availableGroups()) }) { [self] result in
            switch result {
            case .success(let result):
                let (item, owner, availableGroups) = result
                source = item; ownershipSnapshot = owner; groups = availableGroups
                ownership.stringValue = metadataText("Владелец: ", "Owner: ") + "\(owner.ownerName) (UID \(owner.ownerID)) · " + metadataText("Группа: ", "Group: ") + "\(owner.groupName) (GID \(owner.groupID))"
                ownerID.stringValue = String(owner.ownerID)
                groupPicker.removeAllItems(); groupPicker.addItems(withTitles: groups.map(\.title))
                groupPicker.selectItem(at: groups.firstIndex(where: { $0.id == owner.groupID }) ?? 0)
                if !owner.isOwnedByCurrentUser { changeGroup.state = .off }
                let type = item.isSymbolicLink ? metadataText("Символическая ссылка", "Symbolic link") : (item.isDirectory ? metadataText("Папка", "Folder") : metadataText("Файл", "File"))
                details.stringValue = "\(item.url.path)\n\(type) · \(item.size) " + metadataText("байт", "bytes") + " · BSD 0x" + String(item.flags, radix: 16)
                permissions.stringValue = String(format: "%04o", Int(item.permissions))
                accessed.dateValue = item.accessed; modified.dateValue = item.modified; created.dateValue = item.created
                setControlsEnabled(!item.isSymbolicLink)
                previewButton.isEnabled = !item.isSymbolicLink
                if !item.isDirectory { recursive.state = .off; recursive.isEnabled = false }
                if let summary { status.stringValue = summary }
                else if plan == nil { status.stringValue = item.isSymbolicLink ? metadataText("Ссылка доступна только для чтения; её цель не изменяется.", "The symbolic link is read only; its target is unchanged.") : metadataText("Выберите изменения и создайте предпросмотр. Даты доступа/изменения показаны выше.", "Choose changes and create a preview. Access and modification dates are shown above.") }
            case .failure(let error): status.stringValue = error.localizedDescription
            }
        }
    }
    private func selectedChanges() throws -> MetadataChanges {
        var owner: UInt32?
        if changeOwner.state == .on {
            guard let uid = UInt32(ownerID.stringValue), uid < UInt32.max else { throw ExtensionAPIError(metadataText("Укажите числовой UID.", "Enter a numeric UID.")) }
            owner = uid
        }
        func flag(_ picker: NSPopUpButton) -> Bool? { picker.indexOfSelectedItem == 0 ? nil : picker.indexOfSelectedItem == 1 }
        return MetadataChanges(permissions: changePermissions.state == .on ? try FileTools.parsePermissions(permissions.stringValue) : nil,
                        accessed: changeAccessed.state == .on ? accessed.dateValue : nil,
                        modified: changeModified.state == .on ? modified.dateValue : nil,
                        groupID: changeGroup.state == .on && groups.indices.contains(groupPicker.indexOfSelectedItem) ? groups[groupPicker.indexOfSelectedItem].id : nil,
                        created: changeCreated.state == .on ? created.dateValue : nil, ownerID: owner,
                        hidden: flag(hiddenFlag), noDump: flag(noDumpFlag), aclText: pendingACL)
    }
    private func setControlsEnabled(_ enabled: Bool) {
        for control in [permissions, changePermissions, changeAccessed, changeModified, changeCreated,
                        accessed, modified, created, hiddenFlag, noDumpFlag, aclButton] as [NSControl] { control.isEnabled = enabled }
        let canChangeGroup = enabled && ownershipSnapshot?.isOwnedByCurrentUser == true && !groups.isEmpty
        changeGroup.isEnabled = canChangeGroup; groupPicker.isEnabled = canChangeGroup
        changeOwner.isEnabled = enabled && geteuid() == 0; ownerID.isEnabled = changeOwner.isEnabled
        recursive.isEnabled = enabled && source?.isDirectory == true && pendingACL == nil
    }
    @objc private func editACL() {
        guard !isWorking, let window, window.attachedSheet == nil else { return }
        isWorking = true
        setControlsEnabled(false)
        previewButton.isEnabled = false
        worker({ try MetadataMutation.aclText(url: self.url) }) { [weak self] result in
            guard let self else { return }
            self.isWorking = false
            self.setControlsEnabled(true)
            self.previewButton.isEnabled = true
            guard window.isVisible, window.attachedSheet == nil else { return }
            switch result {
            case .success(let text): self.presentACL(text, on: window)
            case .failure(let error): self.status.stringValue = error.localizedDescription
            }
        }
    }
    private func presentACL(_ original: String, on parent: NSWindow) {
        let alert = NSAlert()
        alert.messageText = metadataText("Список управления доступом macOS", "macOS access control list")
        alert.informativeText = metadataText("Текст ACL в формате macOS (!#acl). Пустой список удаляет ACL. Изменение вступит в силу после общего предпросмотра и подтверждения.", "Use macOS ACL text (!#acl). An empty list clears the ACL. The change takes effect after preview and confirmation.")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 630, height: 220))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let editor = NSTextView(frame: scroll.bounds)
        editor.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityLabel(metadataText("Текст ACL", "ACL text"))
        editor.string = pendingACL ?? original
        scroll.documentView = editor
        alert.accessoryView = scroll
        alert.addButton(withTitle: metadataText("Выбрать изменение", "Review this change"))
        alert.addButton(withTitle: L10n.text("Отмена")).keyEquivalent = "\u{1b}"
        if pendingACL != nil { alert.addButton(withTitle: metadataText("Снять изменение ACL", "Discard the ACL change")) }
        alert.beginSheetModal(for: parent) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn || response == .alertThirdButtonReturn else { return }
            if response == .alertFirstButtonReturn, editor.string != original {
                self.pendingACL = editor.string
                self.recursive.state = .off
            } else {
                self.pendingACL = nil
            }
            self.aclStatus.stringValue = self.pendingACL == nil ? "" : metadataText("Выбрано изменение ACL", "ACL change selected")
            self.setControlsEnabled(true)
            self.invalidatePreview()
        }
    }
    @objc private func invalidatePreview() {
        guard !isWorking else { return }
        plan = nil; saveButton.isEnabled = false; preview.string = ""
        status.stringValue = metadataText("Параметры изменены. Создайте новый предпросмотр.", "Settings changed. Create a new preview.")
    }
    @objc private func makePreview() {
        guard !isWorking, source != nil else { return }
        do {
            let changes = try selectedChanges(), recurse = recursive.state == .on
            let token = FileToolCancellation(); cancellation = token
            isWorking = true; setControlsEnabled(false); previewButton.isEnabled = false; saveButton.isEnabled = false; cancelButton.isEnabled = true
            status.stringValue = metadataText("Подготавливается список объектов…", "Preparing the item list…")
            worker({ try MetadataMutation.prepare(url: self.url, changes: changes, recursive: recurse, cancellation: token) }) { [self] result in
                isWorking = false; cancellation = nil; cancelButton.isEnabled = false; setControlsEnabled(true); previewButton.isEnabled = true
                switch result {
                case .success(let reviewed):
                    plan = reviewed
                    preview.string = describe(reviewed)
                    saveButton.isEnabled = true
                    status.stringValue = metadataText("Проверьте список. Изменений ещё нет.", "Review the list. No changes have been applied.")
                case .failure(let error): plan = nil; status.stringValue = error.localizedDescription
                }
            }
        } catch { status.stringValue = error.localizedDescription }
    }
    private func describe(_ plan: MetadataMutationPlan, limit: Int = 200) -> String {
        var lines = [metadataText("Объектов: ", "Items: ") + String(plan.entries.count)]
        if let value = plan.changes.permissions { lines.append(metadataText("Новые права для всех перечисленных объектов: ", "New permissions for every listed item: ") + String(format: "%04o", Int(value))) }
        if let date = plan.changes.accessed { lines.append(metadataText("Дата доступа всех перечисленных объектов: ", "Access date for every listed item: ") + date.formatted()) }
        if let date = plan.changes.modified { lines.append(metadataText("Дата изменения всех перечисленных объектов: ", "Modification date for every listed item: ") + date.formatted()) }
        if let date = plan.changes.created { lines.append(metadataText("Дата создания всех перечисленных объектов: ", "Creation date for every listed item: ") + date.formatted()) }
        if let groupID = plan.changes.groupID { lines.append(metadataText("Новая группа всех перечисленных объектов (GID): ", "New group for every listed item (GID): ") + String(groupID)) }
        if let ownerID = plan.changes.ownerID { lines.append(metadataText("Новый владелец (UID): ", "New owner (UID): ") + String(ownerID)) }
        for (flag, name) in [(plan.changes.hidden, "UF_HIDDEN"), (plan.changes.noDump, "UF_NODUMP")] {
            if let flag { lines.append(name + " · " + (flag ? metadataText("установить", "set") : metadataText("снять", "clear"))) }
        }
        if let acl = plan.changes.aclText {
            lines.append(acl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? metadataText("Очистить ACL.", "Clear the ACL.")
                         : metadataText("Заменить ACL:", "Replace the ACL:"))
            if limit > 6 {
                lines.append(metadataText("Текущий ACL", "Current ACL"))
                lines.append(plan.entries.first?.previousACLText ?? "")
                lines.append(metadataText("Новый ACL", "New ACL"))
                lines.append(acl)
            }
        }
        lines.append(metadataText("Пропущено: ссылки/спецфайлы/другие тома/повторные hardlink: ", "Skipped: links/special files/other volumes/duplicate hard links: ") + "\(plan.skippedSymbolicLinks)/\(plan.skippedSpecialFiles)/\(plan.skippedOtherVolumes)/\(plan.skippedDuplicateHardLinks)")
        if plan.entries.count > limit {
            lines.append(metadataText("Показаны первые ", "Showing the first ") + "\(limit)/\(plan.entries.count). " + metadataText("Применяется весь подготовленный план.", "The entire prepared plan will be applied."))
        }
        lines += plan.entries.prefix(limit).map { entry in
            var previous = String(format: "%04o", Int(entry.previousPermissions)) + " UID \(entry.previousOwnerID) GID \(entry.previousGroupID)"
            if plan.changes.accessed != nil { previous += " · " + metadataText("доступ ", "access ") + entry.previousAccessed.formatted() }
            if plan.changes.modified != nil { previous += " · " + metadataText("изменён ", "modified ") + entry.previousModified.formatted() }
            if plan.changes.created != nil { previous += " · " + metadataText("создан ", "created ") + entry.previousCreated.formatted() }
            if plan.changes.hidden != nil || plan.changes.noDump != nil { previous += " · BSD 0x" + String(entry.previousFlags, radix: 16) }
            return previous + "  " + entry.url.path
        }
        return lines.joined(separator: "\n")
    }
    @objc private func savePermissions() {
        guard let plan, !isWorking else { return }
        guard canMutate() else { status.stringValue = "Другая файловая операция ещё выполняется."; return }
        let alert = NSAlert(); alert.messageText = metadataText("Применить изменения к объектам: ", "Apply changes to items: ") + String(plan.entries.count) + "?"
        alert.informativeText = describe(plan, limit: 6) + "\n\n" + metadataText("Свойства папок применяются после вложенных объектов. Отмена/ошибка оставляет уже выполненные изменения. Новые объекты после предпросмотра не добавляются в план. Отката нет.", "Folder metadata is applied after its children. Cancellation or errors retain completed changes. New entries after the preview are not added to the plan. There is no rollback.")
        alert.addButton(withTitle: L10n.text("Применить")); alert.addButton(withTitle: L10n.text("Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard canMutate() else { return }
        performReviewedPlan(plan)
    }
    private func performReviewedPlan(_ plan: MetadataMutationPlan) {
        guard !isWorking else { return }
        isWorking = true; hasPendingMutation = true
        let token = FileToolCancellation(); cancellation = token
        saveButton.isEnabled = false; previewButton.isEnabled = false; setControlsEnabled(false); cancelButton.isEnabled = true
        worker({
            var lastUpdate = ProcessInfo.processInfo.systemUptime
            return MetadataMutation.apply(plan, cancellation: token) { [weak self] count, total, path in
                let now = ProcessInfo.processInfo.systemUptime
                guard now - lastUpdate >= 0.05 || count == total else { return }
                lastUpdate = now
                DispatchQueue.main.async { self?.status.stringValue = "\(count)/\(total) · \(path)" }
            }
        }) { [self] result in
            isWorking = false; hasPendingMutation = false
            cancellation = nil; self.plan = nil; cancelButton.isEnabled = false
            pendingACL = nil; aclStatus.stringValue = ""
            setControlsEnabled(true); previewButton.isEnabled = true
            onComplete()
            switch result {
            case .success(let report):
                let summary = metadataText("Изменено: ", "Changed: ") + "\(report.completed)/\(report.total). " + (report.isCancelled ? metadataText("Операция отменена. ", "Operation cancelled. ") : "") + (report.error ?? "")
                preview.string += "\n\n" + summary; status.stringValue = summary
                setControlsEnabled(false); previewButton.isEnabled = false
                load(summary: summary)
            case .failure(let error): status.stringValue = error.localizedDescription
            }
        }
    }
    @objc private func cancelWork() { cancellation?.cancel(); status.stringValue = metadataText("Останавливается между объектами…", "Stopping between items…") }
    override func windowWillClose(_ notification: Notification) { cancellation?.cancel(); super.windowWillClose(notification) }
    static func runUISmokeChecks() async throws -> [String] {
        guard AppRuntime.isSmoke, let directory = AppRuntime.smokeStateDirectory else { throw ExtensionAPIError("Properties smoke requires isolated state.") }
        let root = directory.appendingPathComponent("metadata-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("child")
        try Data("original bytes".utf8).write(to: child)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: child.path)
        let originalDate = try FileTools.metadata(child).modified
        let originalAccessed = try FileTools.metadata(child).accessed
        let controller = FilePropertiesWindow(url: root, onComplete: {})
        controller.showWindow(nil); defer { controller.close() }
        func waitFor(_ check: () -> Bool) async throws {
            for _ in 0..<1000 {
                if check() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw ExtensionAPIError("Properties smoke timed out.")
        }
        try await waitFor { controller.source != nil && controller.previewButton.isEnabled }
        guard controller.changeGroup.isEnabled, controller.groupPicker.numberOfItems > 0,
              controller.ownership.stringValue.contains("UID"), controller.ownership.stringValue.contains("GID") else { throw ExtensionAPIError("Properties ownership controls are missing.") }
        controller.changeGroup.state = .on
        controller.changePermissions.state = .on; controller.permissions.stringValue = "0700"
        controller.changeModified.state = .on; controller.modified.dateValue = Date(timeIntervalSince1970: 1_600_000_000)
        controller.recursive.state = .on; controller.invalidatePreview(); controller.makePreview()
        try await waitFor { !controller.isWorking }
        guard let plan = controller.plan, plan.entries.count == 2, controller.saveButton.isEnabled,
              try FileTools.metadata(child).permissions == 0o600,
              try FileTools.metadata(child).modified == originalDate,
              plan.changes.groupID != nil, plan.recursive else { throw ExtensionAPIError("Properties preview changed metadata or omitted its child.") }
        // Exercise the production asynchronous apply path on an isolated reviewed fixture.
        controller.performReviewedPlan(plan)
        try await waitFor { !controller.isWorking && controller.previewButton.isEnabled }
        guard try FileTools.metadata(child).permissions == 0o700,
              try FileTools.metadata(child).modified == Date(timeIntervalSince1970: 1_600_000_000),
              try FileTools.metadata(child).accessed == originalAccessed,
              try MetadataOwnership.snapshot(url: child).groupID == plan.changes.groupID,
              try FileTools.metadata(root).modified == Date(timeIntervalSince1970: 1_600_000_000),
              try String(contentsOf: child, encoding: .utf8) == "original bytes",
              controller.plan == nil, !controller.saveButton.isEnabled else { throw ExtensionAPIError("Properties apply did not apply recursive dates/group or preserve content and the unselected access date.") }
        controller.changePermissions.state = .off; controller.changeModified.state = .off; controller.changeGroup.state = .off
        controller.changeAccessed.state = .on; controller.accessed.dateValue = Date(timeIntervalSince1970: 1_400_000_000)
        controller.invalidatePreview(); controller.makePreview()
        try await waitFor { !controller.isWorking }
        guard let datesOnly = controller.plan, datesOnly.entries.count == 2, datesOnly.recursive,
              datesOnly.changes.permissions == nil, datesOnly.changes.modified == nil, datesOnly.changes.groupID == nil,
              datesOnly.changes.accessed != nil else { throw ExtensionAPIError("Properties recursive date-only preview requires unrelated changes.") }
        // Changing a group choice must discard the reviewed plan, even when the
        // group checkbox is currently off. The production action is shared by
        // all date, checkbox and group controls.
        controller.groupPicker.sendAction(controller.groupPicker.action, to: controller.groupPicker.target)
        guard controller.plan == nil, !controller.saveButton.isEnabled, controller.preview.string.isEmpty else {
            throw ExtensionAPIError("Properties group choice retained a stale preview.")
        }
        controller.makePreview(); try await waitFor { !controller.isWorking }
        guard let accessedPlan = controller.plan else { throw ExtensionAPIError("Properties could not rebuild date-only preview.") }
        controller.performReviewedPlan(accessedPlan)
        try await waitFor { !controller.isWorking && controller.previewButton.isEnabled }
        for item in [root, child] {
            guard try FileTools.metadata(item).accessed == Date(timeIntervalSince1970: 1_400_000_000),
                  try FileTools.metadata(item).modified == Date(timeIntervalSince1970: 1_600_000_000) else {
                throw ExtensionAPIError("Properties recursive access-only change lost the modification date.")
            }
        }
        return ["Properties preview preserves bytes and permissions until apply", "Properties asynchronous apply changes recursive permissions, modification dates and a permitted group", "Properties group selection invalidates its reviewed plan", "Properties recursive access-only changes preserve modification dates"]
    }
}

@MainActor
private func metadataText(_ russian: String, _ english: String) -> String { L10n.language == .english ? english : russian }

@MainActor
final class DirectorySizeWindow: FileToolsWindowController {
    private let cancellation = FileToolCancellation()
    private let progress = NSProgressIndicator()
    private lazy var cancelButton = button("Отменить подсчёт", #selector(cancelCount))
    init(url: URL) {
        super.init(title: "Размер папки — \(url.lastPathComponent)", height: 310)
        let path = NSTextField(wrappingLabelWithString: url.path); path.isSelectable = true
        progress.style = .bar; progress.isIndeterminate = true; progress.startAnimation(nil)
        status.stringValue = "Подсчёт… Символические ссылки не обходятся. Размер — сумма логических размеров обычных файлов."
        content([path, progress, status, cancelButton, NSView()])
        let token = cancellation
        isWorking = true
        worker({ try FileTools.directorySize(url, cancellation: token) }) { [self] result in
            isWorking = false
            progress.stopAnimation(nil); cancelButton.isEnabled = false
            switch result {
            case .success(let size):
                status.stringValue = "\(size.isCancelled ? "Подсчёт отменён. Частичный результат:" : "Результат:")\n\(size.bytes) байт (\(ByteCountFormatter.string(fromByteCount: size.bytes, countStyle: .file)))\nФайлов: \(size.files); вложенных папок: \(size.directories); ссылок: \(size.symbolicLinks).\nНедоступных объектов или ошибок чтения: \(size.unreadable)."
            case .failure(let error): status.stringValue = error.localizedDescription
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func cancelCount() { cancellation.cancel(); status.stringValue = "Отмена подсчёта…" }
    override func windowWillClose(_ notification: Notification) {
        cancellation.cancel(); super.windowWillClose(notification)
    }
}
