import Foundation
import CoreFoundation
import Darwin

/// Portable file references. Import is explicit and captures current identities;
/// exported paths are data, never commands, variables or glob expressions.
public enum TemporaryPanelList {
    public enum Format { case json, lines, nul }
    public static let maximumBytes = 8 * 1024 * 1024
    public static func encode(_ urls: [URL], format: Format = .json) throws -> Data {
        guard urls.allSatisfy({ $0.isFileURL && ($0.host == nil || $0.host == "" || $0.host == "localhost") }) else {
            throw PanelSessionError("Можно экспортировать только локальные пути.")
        }
        let paths = try validated(urls.map(\.path), relativeTo: URL(fileURLWithPath: "/")).map(\.path)
        let data: Data
        switch format {
        case .json:
            data = try JSONSerialization.data(withJSONObject: ["version": 1, "paths": paths], options: [.prettyPrinted, .sortedKeys])
        case .lines:
            guard paths.allSatisfy({ !$0.contains("\n") && !$0.contains("\r") }) else {
                throw PanelSessionError("Имя содержит перевод строки. Выберите JSON или NUL-список.")
            }
            data = Data((paths.joined(separator: "\n") + (paths.isEmpty ? "" : "\n")).utf8)
        case .nul: data = Data((paths.joined(separator: "\0") + (paths.isEmpty ? "" : "\0")).utf8)
        }
        guard data.count <= maximumBytes else { throw PanelSessionError("Список превышает 8 МиБ.") }
        return data
    }
    public static func decode(_ data: Data, format: Format, relativeTo directory: URL) throws -> [URL] {
        guard data.count <= maximumBytes else { throw PanelSessionError("Список превышает 8 МиБ.") }
        var paths: [String]
        switch format {
        case .json:
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == ["version", "paths"], let version = object["version"] as? NSNumber,
                  CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
                  let values = object["paths"] as? [String] else { throw PanelSessionError("Неверный формат JSON-списка версии 1.") }
            paths = values
        case .lines, .nul:
            guard var text = String(data: data, encoding: .utf8) else { throw PanelSessionError("Для списка требуется UTF-8.") }
            if text.hasPrefix("\u{feff}") { text.removeFirst() }
            if format == .lines {
                paths = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
            } else { paths = text.components(separatedBy: "\0") }
            paths.removeAll(where: \.isEmpty)
        }
        return try validated(paths, relativeTo: directory)
    }
    public static func read(_ url: URL, format: Format) throws -> [URL] {
        guard url.isFileURL else { throw PanelSessionError("Нужен локальный файл списка.") }
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw PanelSessionError("Не удалось открыть список.") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= maximumBytes else { throw PanelSessionError("Нужен обычный файл списка до 8 МиБ.") }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw PanelSessionError("Ошибка чтения списка.") }
            if count == 0 { break }
            guard data.count + count <= maximumBytes else { throw PanelSessionError("Список вырос сверх 8 МиБ.") }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_size == info.st_size,
              after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else {
            throw PanelSessionError("Список изменился во время чтения.")
        }
        return try decode(data, format: format, relativeTo: url.deletingLastPathComponent())
    }
    private static func validated(_ paths: [String], relativeTo directory: URL) throws -> [URL] {
        guard directory.isFileURL, paths.count <= 10_000,
              paths.allSatisfy({ !$0.isEmpty && !$0.contains("\0") && $0.utf8.count <= 16_384 && ($0.hasPrefix("/") || !$0.contains("://")) }) else {
            throw PanelSessionError("Список должен содержать до 10 000 локальных путей без NUL.")
        }
        var seen = Set<String>()
        return paths.compactMap { path in
            let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)).standardizedFileURL
            return seen.insert(url.path).inserted ? url : nil
        }
    }
}
