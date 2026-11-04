import Foundation
import FarCore

/// UI paths are archive member names, never host filesystem URLs.
enum ArchiveMutationInput {
    static func resolve(_ value: String, relativeTo base: String, allowRoot: Bool = false) throws -> String {
        guard !value.isEmpty else { throw ArchiveError.invalidPath(value) }
        let absolute = value.hasPrefix("/")
        let input = absolute ? String(value.dropFirst()) : value
        let path = absolute || base.isEmpty ? input : base + "/" + input
        if allowRoot && path.isEmpty { return "" }
        guard !path.isEmpty, !path.contains("\\"), !path.contains("\0"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ArchiveError.invalidPath(value)
        }
        return path
    }
    static func mapping(paths: [String], destination: String, relativeTo base: String) throws -> [String: String] {
        let target = try resolve(destination, relativeTo: base, allowRoot: paths.count > 1)
        var result: [String: String] = [:]
        for path in paths {
            let mapped = paths.count == 1 ? target : (target.isEmpty ? "" : target + "/") + (path as NSString).lastPathComponent
            guard !result.values.contains(mapped) else { throw ArchiveError.duplicatePath(mapped) }
            result[path] = mapped
        }
        return result
    }
}
