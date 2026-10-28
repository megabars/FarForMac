import AppKit

/// A small, independent plain UTF-8 viewer/editor. The original URL may be a
/// symbolic link; all reads and atomic writes use its resolved destination.
@MainActor
final class TextFileWindow: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private static let maximumSize = 8 * 1_024 * 1_024

    private struct FileVersion: Equatable {
        let data: Data
        let modified: Date?
        let inode: UInt64?
        let device: UInt64?
    }

    private enum FileError: LocalizedError {
        case notRegularFile, tooLarge, notText, changed, unstableRead

        var errorDescription: String? {
            switch self {
            case .notRegularFile:
                return "Можно открыть только обычный текстовый файл. Папки и специальные файлы не поддерживаются."
            case .tooLarge:
                return "Размер текста превышает 8 МиБ."
            case .notText:
                return "Файл содержит двоичные данные или не является текстом UTF-8."
            case .changed:
                return "Файл изменён или заменён другой программой. Сохранение отменено, чтобы не перезаписать чужие изменения. Ваши правки остались в окне."
            case .unstableRead:
                return "Файл изменился во время чтения. Откройте его ещё раз."
            }
        }
    }

    private let sourceURL: URL
    private let fileURL: URL
    private let editable: Bool
    private var version: FileVersion
    private var savedText: String
    private let textView = NSTextView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Сохранить", target: nil, action: nil)
    // NSWindow's delegate/target references must never outlive this controller.
    // Also keeps an open window usable if its caller releases its reference.
    private var retainedWhileOpen: TextFileWindow?

    init(url: URL, editable: Bool) throws {
        let original = url.standardizedFileURL
        let resolved = original.resolvingSymlinksInPath().standardizedFileURL
        let loaded = try Self.readVersion(at: resolved)
        guard let contents = String(data: loaded.data, encoding: .utf8),
              Self.isPlainText(loaded.data) else { throw FileError.notText }

        sourceURL = original
        fileURL = resolved
        self.editable = editable
        version = loaded
        savedText = contents

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 560, height: 360)
        window.representedURL = original
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Self.background
        window.center()
        configureContent(contents)
        updateState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        retainedWhileOpen = self
        window?.delegate = self
        super.showWindow(sender)
        window?.makeFirstResponder(textView)
    }

    private static var background: NSColor {
        NSColor(calibratedRed: 0.035, green: 0.065, blue: 0.14, alpha: 1)
    }

    private func configureContent(_ contents: String) {
        guard let content = window?.contentView else { return }
        let name = NSTextField(labelWithString: sourceURL.lastPathComponent)
        name.font = .systemFont(ofSize: 16, weight: .semibold)
        name.lineBreakMode = .byTruncatingMiddle
        let mode = NSTextField(labelWithString: editable ? "Редактирование · UTF-8" : "Только чтение · UTF-8")
        mode.textColor = .secondaryLabelColor
        let path = NSTextField(labelWithString: sourceURL.path)
        path.font = .systemFont(ofSize: 11)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.isSelectable = true
        path.toolTip = sourceURL == fileURL ? sourceURL.path : "Символическая ссылка → \(fileURL.path)"

        let heading = NSStackView(views: [name, mode])
        heading.orientation = .horizontal
        heading.distribution = .fill
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        mode.setContentHuggingPriority(.required, for: .horizontal)
        let header = NSStackView(views: [heading, path])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 5

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.backgroundColor = Self.background
        textView.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isEditable = editable
        textView.isSelectable = true
        textView.allowsUndo = editable
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = Self.background
        textView.textColor = NSColor(calibratedRed: 0.88, green: 0.92, blue: 1, alpha: 1)
        textView.insertionPointColor = .white
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.string = contents
        textView.delegate = self
        scroll.documentView = textView

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        saveButton.target = self
        saveButton.action = #selector(saveDocument(_:))
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = .command
        saveButton.bezelStyle = .rounded
        saveButton.isHidden = !editable
        let closeButton = NSButton(title: "Закрыть", target: self, action: #selector(closeRequested(_:)))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        let footer = NSStackView(views: [statusLabel, spacer, saveButton, closeButton])
        footer.orientation = .horizontal
        footer.spacing = 10
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for view in [header, scroll, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            heading.widthAnchor.constraint(equalTo: header.widthAnchor),
            path.widthAnchor.constraint(equalTo: header.widthAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 13),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
    }

    private var isDirty: Bool { editable && textView.string != savedText }

    func textDidChange(_ notification: Notification) { updateState() }

    private func updateState() {
        window?.title = sourceURL.lastPathComponent + (editable ? " — Редактор" : " — Просмотр")
        window?.isDocumentEdited = isDirty
        saveButton.isEnabled = isDirty
        statusLabel.stringValue = isDirty ? "Есть несохранённые изменения" : (editable ? "Изменений нет" : "Текст можно выделять и копировать")
    }

    @objc func saveDocument(_ sender: Any?) { _ = save() }

    @discardableResult
    private func save() -> Bool {
        guard editable else { return true }
        guard isDirty else { return true }
        do {
            let data = Data(textView.string.utf8)
            guard data.count <= Self.maximumSize else { throw FileError.tooLarge }
            guard Self.isPlainText(data) else { throw FileError.notText }
            // Coordinated access protects against cooperating document writers;
            // version + byte comparison also catches ordinary external edits.
            var coordinationError: NSError?
            var writeError: Error?
            var savedVersion: FileVersion?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            coordinator.coordinate(writingItemAt: fileURL, options: [], error: &coordinationError) { coordinatedURL in
                do {
                    guard fileURL.resolvingSymlinksInPath().standardizedFileURL == fileURL,
                          try Self.readVersion(at: coordinatedURL) == version else { throw FileError.changed }
                    try data.write(to: coordinatedURL, options: .atomic)
                    savedVersion = try Self.readVersion(at: coordinatedURL)
                    guard savedVersion?.data == data else { throw FileError.changed }
                } catch { writeError = error }
            }
            if let error = coordinationError { throw error }
            if let error = writeError { throw error }
            guard let savedVersion else { throw FileError.changed }
            version = savedVersion
            savedText = textView.string
            textView.breakUndoCoalescing()
            updateState()
            return true
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Не удалось сохранить файл"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "ОК")
            alert.runModal()
            return false
        }
    }

    @objc private func closeRequested(_ sender: Any?) { window?.performClose(sender) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmClose()
    }

    /// The application delegate can call this before terminating the app.
    /// A cancelled prompt or failed save returns false and leaves edits intact.
    func confirmClose() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Сохранить изменения в «\(sourceURL.lastPathComponent)»?"
        alert.informativeText = "Несохранённые изменения будут потеряны при закрытии."
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Не сохранять")
        alert.addButton(withTitle: "Отмена")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        retainedWhileOpen = nil
    }

    private static func isPlainText(_ data: Data) -> Bool {
        !data.contains { byte in
            byte == 0 || byte == 127 || (byte < 32 && ![9, 10, 12, 13].contains(byte))
        }
    }

    private static func readVersion(at url: URL) throws -> FileVersion {
        let manager = FileManager.default
        let before = try manager.attributesOfItem(atPath: url.path)
        guard before[.type] as? FileAttributeType == .typeRegular else { throw FileError.notRegularFile }
        guard (before[.size] as? NSNumber)?.intValue ?? 0 <= maximumSize else { throw FileError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumSize + 1) ?? Data()
        guard data.count <= maximumSize else { throw FileError.tooLarge }
        let after = try manager.attributesOfItem(atPath: url.path)
        for key: FileAttributeKey in [.type, .size, .modificationDate, .systemFileNumber, .systemNumber] {
            guard (before[key] as? NSObject) == (after[key] as? NSObject) else { throw FileError.unstableRead }
        }
        guard (after[.size] as? NSNumber)?.intValue == data.count else { throw FileError.unstableRead }
        return FileVersion(
            data: data, modified: after[.modificationDate] as? Date,
            inode: (after[.systemFileNumber] as? NSNumber)?.uint64Value,
            device: (after[.systemNumber] as? NSNumber)?.uint64Value
        )
    }
}
