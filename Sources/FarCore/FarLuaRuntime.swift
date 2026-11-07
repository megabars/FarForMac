import CFarLua
import Foundation

public enum FarLuaLanguage: String, Sendable {
    case lua
    case moonScript

    public init?(pathExtension: String) {
        switch pathExtension.lowercased() {
        case "lua": self = .lua
        case "moon": self = .moonScript
        default: return nil
        }
    }
}

public indirect enum FarLuaValue: Equatable, Sendable {
    case nilValue
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([FarLuaValue])
    case table([String: FarLuaValue])
    case reference(Int)

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var integer: Int64? {
        switch self {
        case .integer(let value): return value
        case .number(let value): return Int64(exactly: value)
        default: return nil
        }
    }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var table: [String: FarLuaValue]? {
        if case .table(let value) = self { return value }
        return nil
    }

    public var array: [FarLuaValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    fileprivate var numeric: Double? {
        switch self {
        case .number(let number): return number
        case .integer(let integer): return Double(integer)
        default: return nil
        }
    }
}

/// A read-only host result for one exact call during registration or a condition.
/// Arguments and results preserve nil positions and the number of return values.
public struct FarLuaQuery: Equatable, Sendable {
    public var name: String
    public var arguments: [FarLuaValue]
    public var results: [FarLuaValue]
    public init(_ name: String, arguments: [FarLuaValue] = [], results: [FarLuaValue]) {
        self.name = name; self.arguments = arguments; self.results = results
    }
    fileprivate var value: FarLuaValue {
        .table(["name": .string(name), "arguments": .array(arguments), "results": .array(results)])
    }
}

public struct FarLuaSnapshot: Equatable, Sendable {
    public var area: String
    public var globals: [String: FarLuaValue]
    public var queryResults: [String: FarLuaValue]
    public var queryCalls: [FarLuaQuery]

    public init(area: String, globals: [String: FarLuaValue] = [:],
                queryResults: [String: FarLuaValue] = [:], queryCalls: [FarLuaQuery] = []) {
        self.area = area
        self.globals = globals
        self.queryResults = queryResults
        self.queryCalls = queryCalls
    }

    fileprivate var value: FarLuaValue {
        .table(["area": .string(area), "globals": .table(globals), "queries": .table(queryResults), "queryCalls": .array(queryCalls.map(\.value))])
    }
}

public struct FarLuaDefinition: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case macro, event, menuItem }

    public let id: Int
    public let kind: Kind
    public let name: String
    public let description: String
    public let areas: [String]
    public let keys: [String]
    public let flags: [String]
    public let group: String?
    public let menu: String?
    public let guid: String?
    public let text: String?
    public let filemask: String?
    public let scriptID: String?
    public let priority: Double

    fileprivate init(_ value: FarLuaValue) throws {
        guard let data = value.table,
              let id = data["id"]?.integer, let kindName = data["kind"]?.string,
              let kind = Kind(rawValue: kindName), let name = data["name"]?.string,
              let description = data["description"]?.string,
              let priority = data["priority"]?.numeric else {
            throw FarLuaError("Malformed Lua declaration.")
        }
        self.id = Int(id)
        self.kind = kind
        self.name = name
        self.description = description
        self.areas = data["areas"]?.array?.compactMap(\.string) ?? []
        self.keys = data["keys"]?.array?.compactMap(\.string) ?? []
        self.flags = data["flags"]?.array?.compactMap(\.string) ?? []
        self.group = data["group"]?.string
        self.menu = data["menu"]?.string
        self.guid = data["guid"]?.string
        self.text = data["text"]?.string
        self.filemask = data["filemask"]?.string
        self.scriptID = data["scriptID"]?.string
        self.priority = priority
    }
}

public struct FarLuaRequest: Equatable, Sendable {
    public let name: String
    public let arguments: [FarLuaValue]
}

public enum FarLuaStep: Equatable, Sendable {
    case request(FarLuaRequest)
    case finished([FarLuaValue])
}

public struct FarLuaError: LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

@MainActor
public final class FarLuaRuntime {
    public private(set) var definitions: [FarLuaDefinition] = []
    public private(set) var isRunning = false
    private let machine: Machine
    private var exports: Set<String> = []
    private var attemptedStartup: Set<Int> = []

    public init() throws {
        machine = try Machine()
    }

    @discardableResult
    public func load(source: String, name: String, language: FarLuaLanguage,
                     snapshot: FarLuaSnapshot = .init(area: "Other"),
                     arguments: [FarLuaValue] = []) throws -> [FarLuaDefinition] {
        try checkSource(source, name: name)
        do {
            let result = try call("load", snapshot: snapshot, [
                "source": .string(source), "name": .string(name), "language": .string(language.rawValue),
                "arguments": .array(arguments)
            ])
            guard let data = result.table, let declarations = data["definitions"]?.array,
                  let exportNames = data["exports"]?.array else {
                throw FarLuaError("Malformed Lua registration result.")
            }
            let loaded = try declarations.map(FarLuaDefinition.init)
            _ = try call("commit", snapshot: .init(area: "Other"))
            definitions.append(contentsOf: loaded)
            exports.formUnion(exportNames.compactMap(\.string))
            return loaded
        } catch {
            _ = try? call("discard", snapshot: .init(area: "Other"))
            throw error
        }
    }

    /// Registers an explicitly supplied module. Its code executes on first require.
    public func loadModule(source: String, name: String, language: FarLuaLanguage) throws {
        try checkSource(source, name: name)
        _ = try call("module", snapshot: .init(area: "Other"), [
            "source": .string(source), "name": .string(name), "language": .string(language.rawValue)
        ])
    }

    public func setPluginStartupInfo(_ properties: [String: FarLuaValue]) throws {
        _ = try call("startupInfo", snapshot: .init(area: "Other"), ["properties": .table(properties)])
    }

    public func hasExport(_ name: String) -> Bool { exports.contains(name) }

    /// Returns the unique highest-priority match, or all contenders in source
    /// order when FAR would open its macro selection menu.
    public func matchingMacros(key: String, snapshot: FarLuaSnapshot) throws -> [FarLuaDefinition] {
        guard !isRunning else { return [] }
        let area = snapshot.area.lowercased()
        let matches = try prioritized(definitions.filter {
            $0.kind == .macro && isInArea($0, area: area) && $0.keys.contains { keyMatches($0, key: key) }
        }, key: key, snapshot: snapshot)
        guard let maximum = matches.map(\.priority).max() else { return [] }
        let highest = matches.filter { $0.priority == maximum }
        if highest.count == 1 { return highest.map(\.definition) }
        return matches.map(\.definition)
    }

    public func matchingEvents(group: String, snapshot: FarLuaSnapshot,
                               arguments: [FarLuaValue] = []) throws -> [FarLuaDefinition] {
        guard !isRunning else { return [] }
        return try prioritized(definitions.filter { $0.kind == .event && $0.group == group.lowercased() },
                               snapshot: snapshot, arguments: arguments)
            .sorted { lhs, rhs in
                lhs.priority == rhs.priority ? lhs.definition.id < rhs.definition.id : lhs.priority > rhs.priority
            }
            .map(\.definition)
    }

    public func startupMacros(snapshot: FarLuaSnapshot) throws -> [FarLuaDefinition] {
        guard !isRunning else { return [] }
        let area = snapshot.area.lowercased()
        let candidates = definitions.filter {
            $0.kind == .macro && isInArea($0, area: area)
                && $0.flags.contains { $0.caseInsensitiveCompare("RunAfterFARStart") == .orderedSame }
                && !attemptedStartup.contains($0.id)
        }
        attemptedStartup.formUnion(candidates.map(\.id))
        return try prioritized(candidates, snapshot: snapshot).map(\.definition)
    }

    public func menuTitle(_ definition: FarLuaDefinition, snapshot: FarLuaSnapshot,
                          menu: String = "Plugins") throws -> String? {
        try checkDefinition(definition)
        return try call("title", snapshot: snapshot,
                        ["id": .integer(Int64(definition.id)), "menu": .string(menu)]).string
    }

    public func start(_ definition: FarLuaDefinition, snapshot: FarLuaSnapshot,
                      arguments: [FarLuaValue] = [], key: String? = nil) throws -> FarLuaStep {
        try checkDefinition(definition)
        return try startAction("start", snapshot: snapshot, [
            "id": .integer(Int64(definition.id)), "arguments": .array(arguments),
            "key": key.map(FarLuaValue.string) ?? .nilValue
        ])
    }

    public func startChunk(source: String, name: String, language: FarLuaLanguage,
                           snapshot: FarLuaSnapshot, arguments: [FarLuaValue] = []) throws -> FarLuaStep {
        try checkSource(source, name: name)
        return try startAction("chunk", snapshot: snapshot, [
            "source": .string(source), "name": .string(name), "language": .string(language.rawValue),
            "arguments": .array(arguments)
        ])
    }

    public func startExport(_ name: String, arguments: [FarLuaValue] = [],
                            snapshot: FarLuaSnapshot) throws -> FarLuaStep {
        guard hasExport(name) else { throw FarLuaError("Unknown Lua export: \(name)") }
        return try startAction("export", snapshot: snapshot, ["export": .string(name), "arguments": .array(arguments)])
    }

    public func resume(with results: [FarLuaValue] = [], snapshot: FarLuaSnapshot) throws -> FarLuaStep {
        try resumeAction(snapshot: snapshot, ["arguments": .array(results)])
    }

    public func resume(throwing message: String, snapshot: FarLuaSnapshot) throws -> FarLuaStep {
        try resumeAction(snapshot: snapshot, ["failure": .string(message)])
    }

    public func cancel() {
        isRunning = false
        _ = try? call("cancel", snapshot: .init(area: "Other"))
    }

    public func makePanelHandle() throws -> FarLuaValue {
        try call("handle", snapshot: .init(area: "Other"))
    }

    public func releaseReference(_ value: FarLuaValue) {
        guard case .reference(let reference) = value else { return }
        _ = try? call("release", snapshot: .init(area: "Other"), ["id": .integer(Int64(reference))])
    }

    private func checkSource(_ source: String, name: String) throws {
        guard !isRunning else { throw FarLuaError("A Lua action is already running.") }
        guard source.utf8.count <= 1024 * 1024, !name.isEmpty, name.utf8.count <= 1024, !name.contains("\0") else {
            throw FarLuaError("Lua source or script name exceeds its limit.")
        }
    }

    private func checkDefinition(_ definition: FarLuaDefinition) throws {
        guard definitions.indices.contains(definition.id - 1), definitions[definition.id - 1] == definition else {
            throw FarLuaError("Unknown Lua declaration.")
        }
    }

    private func prioritized(_ candidates: [FarLuaDefinition], key: String? = nil,
                             snapshot: FarLuaSnapshot, arguments: [FarLuaValue] = []) throws
        -> [(definition: FarLuaDefinition, priority: Double)] {
        let startTime = ProcessInfo.processInfo.systemUptime
        var matches: [(FarLuaDefinition, Double)] = []
        for definition in candidates {
            guard ProcessInfo.processInfo.systemUptime - startTime < 0.25 else {
                throw FarLuaError("Lua macro matching budget exceeded.")
            }
            guard flagsMatch(definition.flags, snapshot: snapshot),
                  try filemaskMatches(definition, snapshot: snapshot) else { continue }
            let result = try call("condition", snapshot: snapshot, [
                "id": .integer(Int64(definition.id)), "key": key.map(FarLuaValue.string) ?? .nilValue,
                "arguments": .array(arguments)
            ])
            if result.bool == true || result.numeric != nil {
                matches.append((definition, result.numeric ?? definition.priority))
            }
        }
        return matches
    }

    private func isInArea(_ definition: FarLuaDefinition, area: String) -> Bool {
        definition.areas.contains { $0.lowercased() == area || $0.lowercased() == "common" }
    }

    private func filemaskMatches(_ definition: FarLuaDefinition, snapshot: FarLuaSnapshot) throws -> Bool {
        guard let pattern = definition.filemask else { return true }
        let area = snapshot.area.lowercased()
        let subject: String?
        switch area {
        case "editor": subject = snapshot.globals["Editor"]?.table?["FileName"]?.string
        case "viewer": subject = snapshot.globals["Viewer"]?.table?["FileName"]?.string
        default: subject = nil
        }
        guard let subject, !subject.isEmpty else { return definition.kind != .event }
        return try FileMask(pattern).matchesChecked((subject as NSString).lastPathComponent)
    }

    private func flagsMatch(_ flags: [String], snapshot: FarLuaSnapshot) -> Bool {
        let area = snapshot.area.lowercased()
        let active = snapshot.globals["APanel"]?.table ?? [:]
        let passive = snapshot.globals["PPanel"]?.table ?? [:]
        let commandLine = snapshot.globals["CmdLine"]?.table
        let panelSelectionApplies = !["editor", "viewer", "dialog"].contains(area)
        let selection: Bool?
        switch area {
        case "editor": selection = snapshot.globals["Editor"]?.table?["Selected"]?.bool
        case "viewer": selection = snapshot.globals["Viewer"]?.table?["Selected"]?.bool
        case "dialog": selection = snapshot.globals["Dlg"]?.table?["Selected"]?.bool
        case "shell": selection = commandLine?["Selected"]?.bool
        default: selection = nil
        }
        for flag in flags.map({ $0.lowercased() }) {
            switch flag {
            case "emptycommandline" where commandLine?["Empty"]?.bool == false: return false
            case "notemptycommandline" where commandLine?["Empty"]?.bool == true: return false
            case "evselection" where selection == false: return false
            case "noevselection" where selection == true: return false
            case "selection" where panelSelectionApplies && active["Selected"]?.bool == false: return false
            case "noselection" where panelSelectionApplies && active["Selected"]?.bool == true: return false
            case "pselection" where panelSelectionApplies && passive["Selected"]?.bool == false: return false
            case "nopselection" where panelSelectionApplies && passive["Selected"]?.bool == true: return false
            case "nofilepanels" where active["Plugin"]?.bool == false: return false
            case "nofileppanels" where passive["Plugin"]?.bool == false: return false
            case "nopluginpanels" where active["Plugin"]?.bool == true: return false
            case "nopluginppanels" where passive["Plugin"]?.bool == true: return false
            case "nofolders" where active["Folder"]?.bool == true: return false
            case "nopfolders" where passive["Folder"]?.bool == true: return false
            case "nofiles" where active["Folder"]?.bool == false: return false
            case "nopfiles" where passive["Folder"]?.bool == false: return false
            default: continue
            }
        }
        return true
    }

    private func keyMatches(_ binding: String, key: String) -> Bool {
        if binding.count > 2, binding.first == "/", binding.last == "/" {
            let pattern = String(binding.dropFirst().dropLast())
            let input = keyName(key, standardSides: true)
            return (try? FileMask("/^(?:\(pattern))$/i").matchesChecked(input)) ?? false
        }
        if binding.caseInsensitiveCompare("none") == .orderedSame { return false }
        let expected = keyParts(binding)
        let actual = keyParts(key)
        return expected.tail == actual.tail && expected.shift == actual.shift
            && modifiersMatch(expected.ctrl, actual.ctrl, generic: "ctrl")
            && modifiersMatch(expected.alt, actual.alt, generic: "alt")
    }

    private func modifiersMatch(_ binding: String, _ key: String, generic: String) -> Bool {
        if binding == generic { return !key.isEmpty }
        if key == generic { return binding == "l" + generic }
        return binding == key
    }

    private func keyName(_ key: String, standardSides: Bool) -> String {
        let parts = keyParts(key)
        let ctrl = parts.ctrl == "ctrl" && standardSides ? "lctrl" : parts.ctrl
        let alt = parts.alt == "alt" && standardSides ? "lalt" : parts.alt
        return ctrl + alt + (parts.shift ? "shift" : "") + parts.tail
    }

    private func keyParts(_ key: String) -> (ctrl: String, alt: String, shift: Bool, tail: String) {
        var remaining = key.lowercased()[...]
        var ctrl = ""
        var alt = ""
        var shift = false
        for _ in 0..<3 {
            if let modifier = ["lctrl", "rctrl", "ctrl"].first(where: { remaining.hasPrefix($0) && remaining.count > $0.count }) {
                ctrl = modifier
                remaining = remaining.dropFirst(modifier.count)
            } else if let modifier = ["lalt", "ralt", "alt"].first(where: { remaining.hasPrefix($0) && remaining.count > $0.count }) {
                alt = modifier
                remaining = remaining.dropFirst(modifier.count)
            } else if remaining.hasPrefix("shift"), remaining.count > 5 {
                shift = true
                remaining = remaining.dropFirst(5)
            } else {
                break
            }
        }
        return (ctrl, alt, shift, String(remaining))
    }

    private func startAction(_ operation: String, snapshot: FarLuaSnapshot,
                             _ payload: [String: FarLuaValue]) throws -> FarLuaStep {
        guard !isRunning else { throw FarLuaError("A Lua action is already running.") }
        return try step(operation, snapshot: snapshot, payload)
    }

    private func resumeAction(snapshot: FarLuaSnapshot, _ payload: [String: FarLuaValue]) throws -> FarLuaStep {
        guard isRunning else { throw FarLuaError("No Lua action is running.") }
        return try step("resume", snapshot: snapshot, payload)
    }

    private func step(_ operation: String, snapshot: FarLuaSnapshot,
                      _ payload: [String: FarLuaValue]) throws -> FarLuaStep {
        do {
            let result = try call(operation, snapshot: snapshot, payload).table
            if result?["status"]?.string == "finished", let values = result?["values"]?.array {
                isRunning = false
                return .finished(values)
            }
            if result?["status"]?.string == "request", let request = result?["request"]?.table,
               let name = request["name"]?.string, let arguments = request["arguments"]?.array {
                isRunning = true
                return .request(.init(name: name, arguments: arguments))
            }
            throw FarLuaError("Malformed Lua action result.")
        } catch {
            cancel()
            throw error
        }
    }

    private func call(_ operation: String, snapshot: FarLuaSnapshot,
                      _ fields: [String: FarLuaValue] = [:]) throws -> FarLuaValue {
        var payload = fields
        payload["snapshot"] = snapshot.value
        return try machine.call(operation, value: .table(payload))
    }

    private final class Machine {
        let pointer: OpaquePointer

        init() throws {
            let bootstrap = Array(FarLuaBootstrap.source.utf8)
            guard let pointer = bootstrap.withUnsafeBufferPointer({ far_lua_create($0.baseAddress, $0.count) }) else {
                throw FarLuaError("Could not allocate Lua runtime.")
            }
            let message = String(cString: far_lua_error(pointer))
            if !message.isEmpty {
                far_lua_destroy(pointer)
                throw FarLuaError(message)
            }
            self.pointer = pointer
        }

        deinit { far_lua_destroy(pointer) }

        func call(_ operation: String, value: FarLuaValue) throws -> FarLuaValue {
            var wire = FarLuaWire()
            try wire.append(value)
            let success = wire.bytes.withUnsafeBufferPointer { far_lua_call(pointer, operation, $0.baseAddress, $0.count) }
            guard success != 0, let output = far_lua_output(pointer) else {
                throw FarLuaError(String(cString: far_lua_error(pointer)))
            }
            wire = FarLuaWire(bytes: Array(UnsafeBufferPointer(start: output, count: far_lua_output_length(pointer))))
            return try wire.read()
        }
    }
}
