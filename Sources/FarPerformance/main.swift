import Foundation
import Darwin
import FarCore

// Deliberately uses production APIs, without launching AppKit windows.
struct BenchmarkError: Error { let message: String }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw BenchmarkError(message: message) }
}
let smoke = CommandLine.arguments.contains("--smoke")
let entries = smoke ? 1_000 : 12_000
let copies = smoke ? [4] : [16, 64]
let env = ProcessInfo.processInfo.environment
let timeLimit = Double(env["FAR_BENCH_MAX_SECONDS"] ?? "60") ?? 60
let rssLimit = Double(env["FAR_BENCH_MAX_RSS_MIB"] ?? "1024") ?? 1024
var metrics: [[String: Any]] = []
func measure<T>(_ name: String, _ body: () throws -> T) throws -> T {
    let start = DispatchTime.now().uptimeNanoseconds
    let result = try autoreleasepool(invoking: body)
    let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    metrics.append(["workload": name, "seconds": seconds])
    try require(seconds <= timeLimit, "\(name) exceeded \(timeLimit)s")
    return result
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("far-benchmark-" + UUID().uuidString, isDirectory: true)
do {
    try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: root) }
    let listing = root.appendingPathComponent("listing", isDirectory: true)
    try fm.createDirectory(at: listing, withIntermediateDirectories: false)
    for index in 0..<entries {
        try Data("\(index % 2 == 0 ? "needle" : "other") \(index)\n".utf8).write(to: listing.appendingPathComponent(String(format: "entry-%06d.txt", index)))
    }
    let items = try measure("list-\(entries)") { try FileService.list(listing, showHidden: true) }
    try require(items.count == entries, "listing count")
    let sorted = try measure("sort-\(entries)") {
        FileService.sorted((0..<entries).map { items[($0 * 7919) % entries] }, options: FileSortOptions(sort: .name))
    }
    try require(sorted.first?.name == "entry-000000.txt", "sort order")
    var options = SearchOptions(roots: [listing])
    options.maximumResults = 10_000
    options.contentMode = .literal; options.contentQuery = "needle"
    let search = try measure("content-search-\(entries)") {
        SearchEngine.run(SearchRequest(options: options), cancellation: SearchCancellation(), onEvent: { _ in })
    }
    try require(search.matches == entries / 2 && search.errors == 0 && !search.limitReached, "search counts")
    for mib in copies {
        let source = root.appendingPathComponent("source-\(mib)")
        let destination = root.appendingPathComponent("copy-\(mib)", isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        // Repeated nonzero bytes avoid sparse-file fixture shortcuts.
        try Data(repeating: 0x5a, count: mib * 1_048_576).write(to: source)
        let result = try measure("copy-\(mib)MiB") {
            TransferEngine.run(TransferRequest(sources: [source], destination: destination, move: false),
                               cancellation: TransferCancellation(), onProgress: { _ in },
                               onConflict: { _ in .cancel }, onError: { _ in .cancel })
        }
        try require(result.completed == 1 && result.failed == 0 && !result.cancelled, "copy failed")
        let sourceBytes = try Data(contentsOf: source)
        let copiedBytes = try Data(contentsOf: destination.appendingPathComponent(source.lastPathComponent))
        try require(sourceBytes == copiedBytes, "copy bytes")
    }
    let editor = root.appendingPathComponent("editor.txt")
    let text = String(repeating: "alpha beta zeta\n", count: 65_536) // exactly 1 MiB
    try Data(text.utf8).write(to: editor)
    let snapshot = try measure("editor-load-1MiB") { try EditorDocument.load(url: editor) }
    let edit = try measure("editor-replace-65536") {
        try EditorEditing.replaceAll(in: snapshot.text, query: EditorSearchQuery(pattern: "beta"), replacement: "BETA")
    }
    try require(edit.count == 65_536, "editor replacement count")
    let saved = try measure("editor-save-1MiB") {
        try EditorDocument.save(text: edit.text, format: snapshot.format, to: editor, expected: snapshot)
    }
    try require(saved.text == edit.text, "editor saved text")
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let rssMiB = Double(usage.ru_maxrss) / 1_048_576 // Darwin reports bytes
    try require(rssMiB <= rssLimit, "peak RSS \(rssMiB) exceeded \(rssLimit) MiB")
    let report: [String: Any] = ["mode": smoke ? "smoke" : "full", "entries": entries,
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "processors": ProcessInfo.processInfo.processorCount, "peakRSSMiB": rssMiB,
        "maximumWorkloadSeconds": timeLimit, "maximumRSSMiB": rssLimit, "metrics": metrics]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} catch {
    fputs("Benchmark failed: \(error)\n", stderr)
    exit(1)
}
