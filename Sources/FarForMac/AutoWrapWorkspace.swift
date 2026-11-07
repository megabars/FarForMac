import AppKit
import FarCore

@MainActor
enum AutoWrapWorkspace {
    private static let settingsKey = "editor.autowrap"
    private struct Configuration {
        let settings: EditorAutoWrapSettings
        let include: FileMask?
        let exclude: FileMask?

        init(_ settings: EditorAutoWrapSettings) throws {
            guard (0...999).contains(settings.rightMargin), settings.includeMasks.utf16.count < 512,
                  settings.excludeMasks.utf16.count < 512 else {
                throw UserCommandError("Правое поле — от 0 до 999. Маска может содержать до 511 символов.")
            }
            self.settings = settings
            include = settings.includeMasks.isEmpty ? nil : try FileMask(settings.includeMasks)
            exclude = settings.excludeMasks.isEmpty ? nil : try FileMask(settings.excludeMasks)
        }
    }

    private static var configuration: Configuration? = {
        if let data = AppPreferences.defaults.data(forKey: settingsKey), data.count <= 8192,
           let settings = try? JSONDecoder().decode(EditorAutoWrapSettings.self, from: data),
           let saved = try? Configuration(settings) { return saved }
        return try? Configuration(.init())
    }()

    static func settings(for filename: String) -> EditorAutoWrapSettings? {
        guard let configuration, configuration.settings.enabled else { return nil }
        // FAR skips the name check, including the exclude list, when the
        // include field is blank.
        guard let include = configuration.include else { return configuration.settings }
        guard (try? include.matchesChecked(filename)) == true,
              (try? configuration.exclude?.matchesChecked(filename)) != true else { return nil }
        return configuration.settings
    }

    static func show() {
        let settings = configuration?.settings ?? .init()
        let enabled = NSButton(checkboxWithTitle: "Автоматический перенос", target: nil, action: nil)
        enabled.state = settings.enabled ? .on : .off
        let margin = NSTextField(string: String(settings.rightMargin))
        margin.widthAnchor.constraint(equalToConstant: 65).isActive = true
        let include = NSTextField(string: settings.includeMasks), exclude = NSTextField(string: settings.excludeMasks)
        include.widthAnchor.constraint(equalToConstant: 420).isActive = true
        exclude.widthAnchor.constraint(equalToConstant: 420).isActive = true
        let marginRow = NSStackView(views: [margin, NSTextField(labelWithString: "Правое поле")])
        marginRow.spacing = 8
        let form = NSStackView(views: [enabled, marginRow,
            NSTextField(labelWithString: "Маски файлов для переноса, через запятую"), include,
            NSTextField(labelWithString: "Маски исключений, через запятую"), exclude])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        form.frame = NSRect(x: 0, y: 0, width: 430, height: 164)
        let alert = NSAlert()
        alert.messageText = "Автоперенос"
        alert.accessoryView = form
        alert.addButton(withTitle: "ОК")
        alert.addButton(withTitle: "Отмена")
        while alert.runModal() == .alertFirstButtonReturn {
            do {
                var requested = EditorAutoWrapSettings()
                requested.enabled = enabled.state == .on
                requested.rightMargin = Int(margin.stringValue) ?? -1
                requested.includeMasks = include.stringValue
                requested.excludeMasks = exclude.stringValue
                let validated = try Configuration(requested)
                AppPreferences.defaults.set(try JSONEncoder().encode(requested), forKey: settingsKey)
                configuration = validated
                return
            } catch { NSAlert(error: error).runModal() }
        }
    }
}

extension AutoWrapWorkspace {
    static func withSmokeSettings<T>(_ settings: EditorAutoWrapSettings, perform: () throws -> T) throws -> T {
        guard AppRuntime.isSmoke else { throw ExtensionAPIError("AutoWrap smoke requires isolated state.") }
        let saved = configuration
        defer { configuration = saved }
        configuration = try Configuration(settings)
        return try perform()
    }
}
