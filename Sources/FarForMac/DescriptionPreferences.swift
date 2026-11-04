import Foundation
import FarCore

/// Only an explicit per-folder choice permits interpreting a legacy description file.
@MainActor
enum DescriptionPreferences {
    private static let encodingsKey = "descriptions.encodings.v1"
    static var enabled: Bool {
        get { AppPreferences.defaults.object(forKey: "descriptions.propagate") as? Bool ?? true }
        set { AppPreferences.defaults.set(newValue, forKey: "descriptions.propagate") }
    }
    static var encodings: [String: FileDescriptionEncoding] {
        guard let data = AppPreferences.defaults.data(forKey: encodingsKey), data.count <= 1024 * 1024,
              let value = try? JSONDecoder().decode([String: FileDescriptionEncoding].self, from: data), value.count <= 1000 else { return [:] }
        return value.filter { $0.key.hasPrefix("/") && !$0.key.contains("\0") && $0.key.utf8.count <= 16_384 }
    }
    static func encodings(forSources sources: [URL], destination: URL) -> [String: FileDescriptionEncoding] {
        let sourceKeys = sources.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        let destinationKey = destination.standardizedFileURL.resolvingSymlinksInPath().path
        let parents = Set((sources + [destination]).map { $0.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path })
        return encodings.filter { key, _ in
            parents.contains(key) || sourceKeys.contains(where: { key == $0 || key.hasPrefix($0 + "/") }) ||
                key == destinationKey || key.hasPrefix(destinationKey + "/")
        }
    }
    static func encoding(for directory: URL) -> FileDescriptionEncoding {
        encodings[directory.standardizedFileURL.resolvingSymlinksInPath().path] ?? .utf8
    }
    static func setEncoding(_ encoding: FileDescriptionEncoding, for directory: URL) {
        var values = encodings
        let key = directory.standardizedFileURL.resolvingSymlinksInPath().path
        if encoding == .utf8 { values.removeValue(forKey: key) }
        else { values[key] = encoding }
        guard values.count <= 1000, let data = try? JSONEncoder().encode(values), data.count <= 1024 * 1024 else { return }
        AppPreferences.defaults.set(data, forKey: encodingsKey)
    }
}
