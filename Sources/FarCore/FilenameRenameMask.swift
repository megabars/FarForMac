import Foundation

/// Destination-name masks, verified against FAR's processname.cpp ConvertWildcards
/// at 1a6b02544b339615232078e0551463ef15b73ff9. This is not a selection glob:
/// brackets and braces are literal; `?`, `*` and dots consume the source name.
/// Windows wchar_t positions are UTF-16 units. A split surrogate is rejected.
public struct FilenameRenameMask: Sendable {
    private let mask: [UInt16]

    public init(_ mask: String) throws {
        try Self.checkComponent(mask)
        guard mask.utf16.count <= 4_096 else { throw Failure("Маска переименования длиннее 4096 позиций UTF-16.") }
        self.mask = Array(mask.utf16)
    }

    public func destinationName(for source: String) throws -> String {
        try Self.checkComponent(source)
        let original = Array(source.utf16)
        guard original.count <= 65_536 else { throw Failure("Слишком длинное исходное имя.") }
        guard mask.contains(42) || mask.contains(63) else { return String(decoding: mask, as: UTF16.self) }
        var result = [UInt16]()
        var sourcePosition = 0
        var maskPosition = 0
        while maskPosition < mask.count {
            let unit = mask[maskPosition]
            maskPosition += 1
            switch unit {
            case 63: // ? copies one source position, except a dot or end of name.
                if sourcePosition < original.count, original[sourcePosition] != 46 {
                    result.append(original[sourcePosition]); sourcePosition += 1
                }
            case 42: // * and its following position form one operation.
                if maskPosition < mask.count {
                    let next = mask[maskPosition]; maskPosition += 1
                    let end = next == 63 ? original.count :
                        (original[sourcePosition...].lastIndex(of: next) ?? original.count)
                    result.append(contentsOf: original[sourcePosition..<end])
                    if next != 63 { result.append(next) }
                    sourcePosition = min(end + 1, original.count)
                } else {
                    result.append(contentsOf: original[sourcePosition...])
                }
            case 46: // An explicit dot skips through the first remaining source dot.
                result.append(unit)
                sourcePosition = original[sourcePosition...].firstIndex(of: 46).map { $0 + 1 } ?? original.count
            default:
                result.append(unit)
                if sourcePosition < original.count, original[sourcePosition] != 46 { sourcePosition += 1 }
            }
        }
        if result.last == 46 { result.removeLast() }
        let name = String(decoding: result, as: UTF16.self)
        guard Array(name.utf16) == result else {
            throw Failure("Маска разделяет символ Unicode. Используйте две позиции ? для символа вне BMP или маску *.")
        }
        return name
    }

    private static func checkComponent(_ value: String) throws {
        guard !value.isEmpty, !value.contains("/"), !value.contains("\\"), !value.contains("\0") else {
            throw Failure("Маска и исходное имя должны содержать только имя: пути, разделители папок и NUL запрещены.")
        }
    }
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}

public enum BatchRenameMode: String, Sendable {
    case template
    case farMask
}
