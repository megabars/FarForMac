import Foundation

/// Ordered priority masks: first matching upper rule, then lower rule, wins.
/// Smaller ranks sort first, with unmatched files at zero. Group order remains
/// unchanged when the ordinary filename/extension sort direction is reversed.
public struct SortGroups: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var upper: [String]
    public var lower: [String]
    public init(enabled: Bool = false, upper: [String] = [], lower: [String] = []) {
        self.enabled = enabled; self.upper = upper; self.lower = lower
    }
    public static let maximumRules = 100
    public static let maximumJSONSize = 512 * 1_024

    public func validate(maskGroups: [String: String] = [:]) throws {
        _ = try compiled(maskGroups: maskGroups)
    }
    public static func decode(_ data: Data, maskGroups: [String: String] = [:]) throws -> Self {
        guard data.count <= maximumJSONSize else { throw SortGroupError("Настройки групп сортировки слишком велики.") }
        let settings: Self
        do { settings = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw SortGroupError("Некорректный JSON групп сортировки. Нужны enabled (true/false), upper и lower (массивы масок).") }
        try settings.validate(maskGroups: maskGroups)
        return settings
    }
    public func jsonData() throws -> Data {
        // Named groups are resolved when settings are applied; structural limits
        // also protect callers serializing settings before their groups exist.
        try validateStructure()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumJSONSize else { throw SortGroupError("Настройки групп сортировки слишком велики.") }
        return data
    }

    /// Evaluate before sorting so comparator calls remain fast and deterministic.
    /// A shared wall-clock budget bounds the entire batch, including all rules.
    public func ranks(for names: [String], maskGroups: [String: String] = [:], timeLimit: TimeInterval = 0.25) throws -> [String: Int] {
        guard timeLimit.isFinite, timeLimit > 0 else { throw SortGroupError("Время проверки групп должно быть положительным конечным числом.") }
        guard enabled else { return [:] }
        let start = ProcessInfo.processInfo.systemUptime
        let rules = try compiled(maskGroups: maskGroups)
        var ranks = [String: Int]()
        for name in names {
            var rank = 0
            for (index, rule) in rules.enumerated() {
                let remaining = timeLimit - (ProcessInfo.processInfo.systemUptime - start)
                guard remaining > 0 else { throw SortGroupError("Превышено время проверки групп сортировки.") }
                if try rule.matchesChecked(name, timeLimit: remaining) {
                    rank = index < upper.count ? index - upper.count : index - upper.count + 1
                    break
                }
            }
            guard ProcessInfo.processInfo.systemUptime - start < timeLimit else { throw SortGroupError("Превышено время проверки групп сортировки.") }
            ranks[name] = rank
        }
        return ranks
    }

    private func validateStructure() throws {
        guard upper.count + lower.count <= Self.maximumRules else { throw SortGroupError("Допустимо не более 100 правил сортировки.") }
        guard (upper + lower).allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf16.count <= 4_096 }) else {
            throw SortGroupError("Каждое правило должно содержать непустую маску длиной до 4096 символов.")
        }
    }
    private func compiled(maskGroups: [String: String]) throws -> [FileMask] {
        try validateStructure()
        return try (upper + lower).enumerated().map { index, pattern in
            do { return try FileMask(pattern, groups: maskGroups) }
            catch { throw SortGroupError("Правило \(index + 1): \(error.localizedDescription)") }
        }
    }
    private struct SortGroupError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
