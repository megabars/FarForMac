import AppKit
import FarCore
import Darwin

/// App-owned test isolation: never overrides HOME, the system locale or existing defaults.
@MainActor
enum AppRuntime {
    static private(set) var smokeReport: URL?
    static private(set) var smokeDirectory: URL?
    static private(set) var smokeStateDirectory: URL?
    static var isSmoke: Bool { smokeReport != nil }
    static func configure() throws {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--ui-smoke-report") else { return }
        guard arguments.indices.contains(index + 1), arguments[index + 1].hasPrefix("/") else {
            throw NSError(domain: "Smoke", code: 2, userInfo: [NSLocalizedDescriptionKey: "--ui-smoke-report requires an absolute JSON output path"])
        }
        smokeReport = URL(fileURLWithPath: arguments[index + 1])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FarForMac-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        smokeStateDirectory = directory
        let files = directory.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: false)
        smokeDirectory = files
        try Data("smoke fixture\n".utf8).write(to: files.appendingPathComponent("sample.txt"))
        try Data("{\"smoke\":true}\n".utf8).write(to: files.appendingPathComponent("Имя"))
    }
    static var commandStore: UserCommandStore { UserCommandStore(globalURL: smokeStateDirectory?.appendingPathComponent("commands.json") ?? UserCommandStore.defaultGlobalURL) }
    static var recoveryStore: EditorRecoveryStore { EditorRecoveryStore(directory: smokeStateDirectory?.appendingPathComponent("Recovery")) }
    static var historyURL: URL { smokeStateDirectory?.appendingPathComponent("history.json") ?? CommandHistory.defaultFileURL }
    static func finishSmoke(checks: [String], error: String? = nil) -> Never {
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        let report: [String: Any] = ["status": error == nil ? "passed" : "failed", "checks": checks, "error": error ?? "", "architecture": architecture, "os": ProcessInfo.processInfo.operatingSystemVersionString]
        var success = error == nil
        do {
            guard let smokeReport else { throw NSError(domain: "Smoke", code: 1) }
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: smokeReport, options: .atomic)
        } catch { fputs("UI smoke report failed: \(error)\n", stderr); success = false }
        AppPreferences.cleanSmokeDomain()
        if let smokeStateDirectory { try? FileManager.default.removeItem(at: smokeStateDirectory) }
        exit(success ? 0 : 1)
    }
}

@MainActor
enum AppPreferences {
    private static let smokeDomain = "dev.farmac.smoke.\(UUID().uuidString)"
    static let defaults: UserDefaults = AppRuntime.isSmoke ? UserDefaults(suiteName: smokeDomain)! : .standard
    static func cleanSmokeDomain() {
        if AppRuntime.isSmoke { defaults.removePersistentDomain(forName: smokeDomain); defaults.synchronize() }
    }
}
