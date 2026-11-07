import Foundation

// The bounded value protocol belongs to the Lua bridge. Bytes are little endian;
// payloads carry their own string and collection lengths.
struct FarLuaWire {
    private enum Tag: UInt8 {
        case nilValue, falseValue, trueValue, integer, number, string, array, table, reference
    }

    private static let maximumDepth = 24
    private static let maximumNodes = 32_768
    private static let maximumBytes = 4 * 1024 * 1024

    private(set) var bytes: [UInt8]
    private var offset = 0
    private var nodes = 0

    init(bytes: [UInt8] = []) { self.bytes = bytes }

    mutating func append(_ value: FarLuaValue) throws {
        try append(value, depth: 0)
    }

    private mutating func append(_ value: FarLuaValue, depth: Int) throws {
        try checkNode(depth: depth)
        switch value {
        case .nilValue: bytes.append(Tag.nilValue.rawValue)
        case .bool(let value): bytes.append(value ? Tag.trueValue.rawValue : Tag.falseValue.rawValue)
        case .integer(let integer):
            bytes.append(Tag.integer.rawValue)
            append(UInt64(bitPattern: integer), width: 8)
        case .number(let number):
            bytes.append(Tag.number.rawValue)
            append(number.bitPattern, width: 8)
        case .string(let string):
            let utf8 = string.utf8
            guard utf8.count <= Self.maximumBytes - bytes.count - 5 else { throw malformed() }
            bytes.append(Tag.string.rawValue)
            append(UInt64(utf8.count), width: 4)
            bytes.append(contentsOf: utf8)
        case .array(let values):
            try appendCollection(.array, count: values.count)
            for value in values { try append(value, depth: depth + 1) }
        case .table(let values):
            try appendCollection(.table, count: values.count)
            for (name, value) in values {
                try append(.string(name), depth: depth + 1)
                try append(value, depth: depth + 1)
            }
        case .reference(let reference):
            guard reference > 0, let id = UInt32(exactly: reference) else { throw malformed() }
            bytes.append(Tag.reference.rawValue)
            append(UInt64(id), width: 4)
        }
        guard bytes.count <= Self.maximumBytes else { throw malformed() }
    }

    private mutating func appendCollection(_ tag: Tag, count: Int) throws {
        guard count <= Self.maximumNodes else { throw malformed() }
        bytes.append(tag.rawValue)
        append(UInt64(count), width: 4)
    }

    private mutating func append(_ number: UInt64, width: Int) {
        for i in 0..<width { bytes.append(UInt8(truncatingIfNeeded: number >> (i * 8))) }
    }

    mutating func read() throws -> FarLuaValue {
        let value = try read(depth: 0)
        guard offset == bytes.count else { throw malformed() }
        return value
    }

    private mutating func read(depth: Int) throws -> FarLuaValue {
        try checkNode(depth: depth)
        guard let tag = Tag(rawValue: UInt8(try readUnsigned(width: 1))) else { throw malformed() }
        switch tag {
        case .nilValue: return .nilValue
        case .falseValue: return .bool(false)
        case .trueValue: return .bool(true)
        case .integer: return .integer(Int64(bitPattern: try readUnsigned(width: 8)))
        case .number: return .number(Double(bitPattern: try readUnsigned(width: 8)))
        case .reference: return .reference(Int(try readUnsigned(width: 4)))
        case .string:
            let length = Int(try readUnsigned(width: 4))
            guard length <= bytes.count - offset,
                  let result = String(bytes: bytes[offset..<(offset + length)], encoding: .utf8) else {
                throw FarLuaError("Lua host text must be valid UTF-8.")
            }
            offset += length
            return .string(result)
        case .array:
            let count = try readCollectionCount()
            var result: [FarLuaValue] = []
            result.reserveCapacity(count)
            for _ in 0..<count { result.append(try read(depth: depth + 1)) }
            return .array(result)
        case .table:
            let count = try readCollectionCount()
            var result: [String: FarLuaValue] = [:]
            result.reserveCapacity(count)
            for _ in 0..<count {
                guard case .string(let name) = try read(depth: depth + 1) else { throw malformed() }
                result[name] = try read(depth: depth + 1)
            }
            return .table(result)
        }
    }

    private mutating func readCollectionCount() throws -> Int {
        let count = Int(try readUnsigned(width: 4))
        guard count <= Self.maximumNodes else { throw malformed() }
        return count
    }

    private mutating func readUnsigned(width: Int) throws -> UInt64 {
        guard width <= bytes.count - offset else { throw malformed() }
        var result: UInt64 = 0
        for i in 0..<width { result |= UInt64(bytes[offset + i]) << (i * 8) }
        offset += width
        return result
    }

    private mutating func checkNode(depth: Int) throws {
        nodes += 1
        guard depth < Self.maximumDepth, nodes <= Self.maximumNodes else { throw malformed() }
    }

    private func malformed() -> FarLuaError { FarLuaError("Lua bridge value is invalid or exceeds its limits.") }
}
