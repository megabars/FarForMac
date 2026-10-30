import Foundation
import Darwin

public struct PanelTreeEntry: Sendable {
    public let url: URL
    public let isSymbolicLink: Bool
    public var name: String { url.lastPathComponent }
}

public struct PanelTreeListing: Sendable {
    public let entries: [PanelTreeEntry]
    public let unreadable: Int
    public let truncated: Bool
}

public struct PanelItemInformation: Sendable {
    public let url: URL
    public let kind: String
    public let bytes: Int64
    public let permissions: String
    public let modified: Date
    public let owner: String
    public let linkDestination: String?
}

public struct PanelInformation: Sendable {
    public let directory: URL
    public let volumeName: String?
    public let totalBytes: Int64?
    public let freeBytes: Int64?
    public let item: PanelItemInformation
}

public struct PanelPreview: Sendable {
    public let text: String
    public let encoding: ViewerEncoding
    public let totalBytes: Int64
    public let displayedBytes: Int64
    public let isTruncated: Bool
    public let isBinary: Bool
}

public struct PanelDirectorySize: Sendable {
    public fileprivate(set) var bytes: Int64 = 0
    public fileprivate(set) var files = 0
    public fileprivate(set) var directories = 0
    public fileprivate(set) var symbolicLinks = 0
    public fileprivate(set) var unreadable = 0
    public fileprivate(set) var isCancelled = false
    public var isPartial: Bool { unreadable > 0 || isCancelled }
}

/// Read-only local inspection. Call on a worker queue; cancellation is cooperative
/// between filesystem calls. A blocked filesystem call has no hard time limit.
public enum PanelInspection {
    public static let maximumTreeChildren = 10_000
    public static let maximumPreviewBytes = 65_536
    public static let maximumDirectoryDepth = 128

    public static func treeChildren(
        _ directory: URL, showHidden: Bool = false,
        cancellation: FileToolCancellation = FileToolCancellation(),
        limit: Int = maximumTreeChildren
    ) throws -> PanelTreeListing {
        try check(cancellation)
        let fd = try openDirectory(directory)
        defer { Darwin.close(fd) }
        var entries: [PanelTreeEntry] = [], unreadable = 0, truncated = false
        try children(fd) { name in
            try check(cancellation)
            if !showHidden && name.hasPrefix(".") { return true }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { unreadable += 1; return true }
            let link = info.st_mode & S_IFMT == S_IFLNK
            if link {
                var target = stat()
                guard fstatat(fd, name, &target, 0) == 0, target.st_mode & S_IFMT == S_IFDIR else { return true }
            } else if info.st_mode & S_IFMT != S_IFDIR { return true }
            guard entries.count < max(0, min(limit, maximumTreeChildren)) else { truncated = true; return false }
            entries.append(PanelTreeEntry(url: directory.appendingPathComponent(name, isDirectory: true), isSymbolicLink: link))
            return true
        }
        try check(cancellation)
        entries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return PanelTreeListing(entries: entries, unreadable: unreadable, truncated: truncated)
    }

    public static func information(
        directory: URL, selected: URL? = nil,
        cancellation: FileToolCancellation = FileToolCancellation()
    ) throws -> PanelInformation {
        try check(cancellation)
        guard directory.isFileURL else { throw ViewerError.unsupportedURL }
        let url = selected ?? directory
        guard url.isFileURL else { throw ViewerError.unsupportedURL }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw failure(url) }
        let link = info.st_mode & S_IFMT == S_IFLNK
        let kind: String
        switch info.st_mode & S_IFMT {
        case S_IFDIR: kind = "Папка"
        case S_IFREG: kind = "Файл"
        case S_IFLNK: kind = "Символическая ссылка"
        default: kind = "Специальный файл"
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let disk = try? FileManager.default.attributesOfFileSystem(forPath: directory.path)
        let volume = try? directory.resourceValues(forKeys: [.volumeNameKey])
        let item = PanelItemInformation(
            url: url, kind: kind, bytes: Int64(info.st_size), permissions: String(format: "%04o", info.st_mode & 0o7777),
            modified: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000),
            owner: attributes?[.ownerAccountName] as? String ?? String(info.st_uid),
            linkDestination: link ? try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) : nil
        )
        try check(cancellation)
        return PanelInformation(directory: directory, volumeName: volume?.volumeName,
                                totalBytes: (disk?[.systemSize] as? NSNumber)?.int64Value,
                                freeBytes: (disk?[.systemFreeSize] as? NSNumber)?.int64Value, item: item)
    }

    /// One bounded page, irrespective of file size. Binary bytes are rendered as
    /// hex so control characters cannot obscure the panel or its status.
    public static func preview(
        _ url: URL, cancellation: FileToolCancellation = FileToolCancellation()
    ) throws -> PanelPreview {
        try check(cancellation)
        let source = try LocalViewerSource(url: url)
        let document = try ViewerDocument(source: source)
        try check(cancellation)
        let page = try document.page(at: 0, byteCount: maximumPreviewBytes)
        let binary = page.text.unicodeScalars.contains {
            ($0.value < 32 && ![9, 10, 13].contains($0.value)) || $0.value == 127
        }
        let text: String
        let displayed: Int64
        if binary {
            // Hex has a larger text footprint; 4 KiB is enough for identification.
            let data = try source.read(offset: 0, count: Int(min(source.size, 4096)))
            text = stride(from: 0, to: data.count, by: 16).map { offset in
                let row = data[offset..<min(data.count, offset + 16)]
                return String(format: "%08X  ", offset) + row.map { String(format: "%02X", $0) }.joined(separator: " ")
            }.joined(separator: "\n")
            displayed = Int64(data.count)
        } else { text = page.text; displayed = page.endOffset }
        try check(cancellation)
        try source.verifyUnchanged()
        return PanelPreview(text: text, encoding: document.encoding, totalBytes: source.size,
                            displayedBytes: displayed, isTruncated: displayed < source.size, isBinary: binary)
    }

    /// Logical regular-file bytes. Every hardlink directory entry is counted;
    /// symlinks and special files are never followed. Errors/depth limits remain
    /// visible in `unreadable`, and cancellation preserves explicitly partial totals.
    public static func directorySize(
        _ directory: URL, cancellation: FileToolCancellation = FileToolCancellation(),
        onProgress: (PanelDirectorySize) -> Void = { _ in }
    ) throws -> PanelDirectorySize {
        try check(cancellation)
        let fd = try openDirectory(directory)
        defer { Darwin.close(fd) }
        var result = PanelDirectorySize(), visited = Set<String>(), updates = 0
        func scan(_ directoryFD: Int32, depth: Int) {
            guard !cancellation.isCancelled else { return }
            var root = stat()
            guard fstat(directoryFD, &root) == 0 else { result.unreadable += 1; return }
            let identity = "\(root.st_dev):\(root.st_ino)"
            guard visited.insert(identity).inserted else { result.unreadable += 1; return }
            defer { visited.remove(identity) }
            do {
                try children(directoryFD) { name in
                    guard !cancellation.isCancelled else { return false }
                    var info = stat()
                    guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                        result.unreadable += 1; return true
                    }
                    switch info.st_mode & S_IFMT {
                    case S_IFDIR:
                        result.directories += 1
                        if depth >= maximumDirectoryDepth { result.unreadable += 1 }
                        else {
                            let child = openat(directoryFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                            if child < 0 { result.unreadable += 1 }
                            else {
                                var opened = stat()
                                if fstat(child, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino {
                                    scan(child, depth: depth + 1)
                                } else { result.unreadable += 1 }
                                Darwin.close(child)
                            }
                        }
                    case S_IFREG:
                        result.files += 1
                        let sum = result.bytes.addingReportingOverflow(Int64(info.st_size))
                        if sum.overflow { result.unreadable += 1 } else { result.bytes = sum.partialValue }
                    case S_IFLNK: result.symbolicLinks += 1
                    default: break
                    }
                    updates += 1
                    if updates % 128 == 0 { onProgress(result) }
                    return !cancellation.isCancelled
                }
            } catch { result.unreadable += 1 }
        }
        scan(fd, depth: 0)
        result.isCancelled = cancellation.isCancelled
        onProgress(result)
        return result
    }

    private static func check(_ cancellation: FileToolCancellation) throws {
        if cancellation.isCancelled { throw ViewerError.cancelled }
    }

    private static func openDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL else { throw ViewerError.unsupportedURL }
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure(url) }
        return fd
    }

    private static func failure(_ url: URL) -> ViewerError {
        .io("\(url.path): \(String(cString: strerror(errno)))")
    }

    private static func children(_ fd: Int32, body: (String) throws -> Bool) throws {
        let copy = dup(fd)
        guard copy >= 0 else { throw ViewerError.io(String(cString: strerror(errno))) }
        guard let stream = fdopendir(copy) else {
            let error = ViewerError.io(String(cString: strerror(errno))); Darwin.close(copy); throw error
        }
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw ViewerError.io(String(cString: strerror(errno))) }
                return
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            if try !body(name) { return }
        }
    }
}
