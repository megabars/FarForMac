import Foundation
import Darwin
import CArchive

public enum ArchiveOverwritePolicy: Sendable { case replace, skip, error }
public enum ArchiveWriteError: LocalizedError {
    case conflict(String), encryptedReadOnly, sourceChanged(String), io(String)
    public var errorDescription: String? {
        switch self {
        case .conflict(let path): return "Объект уже существует в архиве: «\(path)»."
        case .encryptedReadOnly: return "Зашифрованные архивы доступны только для чтения: сохранение шифрования не поддерживается."
        case .sourceChanged(let path): return "Источник изменился: «\(path)»."
        case .io(let text): return text
        }
    }
}

/// Synchronous, transactional archive worker. Invoke away from the main thread.
/// Only regular files and directories are accepted; sources are never moved or deleted.
public enum ArchiveWriter {
    public static func create(sources: [URL], destination: URL, format: ArchiveFormat,
                              policy: ArchiveOverwritePolicy = .error,
                              cancellation: TransferCancellation = TransferCancellation(),
                              onProgress: @escaping (ArchiveProgress) -> Void = { _ in }) throws -> ArchiveSnapshot {
        let worker = ArchiveWriteWorker(cancellation, onProgress)
        let target = try worker.destination(destination)
        let old = try WriteStamp.optional(target)
        if old != nil {
            switch policy {
            case .error: throw ArchiveWriteError.conflict(target.path)
            case .skip: return try ArchiveReader.open(target, cancellation: cancellation, onProgress: onProgress)
            case .replace: guard old!.regular else { throw ArchiveError.unsafeEntry(target.path) }
            }
        }
        var nodes: [String: WriteNode] = [:]
        for source in sources {
            try worker.validateSource(source, against: target)
            try worker.add(source, path: source.lastPathComponent, to: &nodes, policy: policy)
        }
        return try worker.commit(nodes, to: target, format: format, original: old, snapshot: nil)
    }

    public static func update(_ snapshot: ArchiveSnapshot, additions: [URL] = [], deletions: [String] = [],
                              replacements: [String: URL] = [:], prefix: String = "",
                              policy: ArchiveOverwritePolicy = .error,
                              cancellation: TransferCancellation = TransferCancellation(),
                              onProgress: @escaping (ArchiveProgress) -> Void = { _ in }) throws -> ArchiveSnapshot {
        let worker = ArchiveWriteWorker(cancellation, onProgress)
        try worker.check()
        try snapshot.verifyCurrent()
        guard !snapshot.entries.contains(where: \.isEncrypted) else { throw ArchiveWriteError.encryptedReadOnly }
        let target = try worker.destination(snapshot.sourceURL)
        let original = try WriteStamp(target)
        let headers = try worker.headers(snapshot)
        let workspace = try ArchiveReader.extract(snapshot, cancellation: cancellation, onProgress: onProgress)
        defer { workspace.cleanup() }
        var nodes: [String: WriteNode] = [:]
        for entry in snapshot.entries {
            let path = try worker.path(entry.path)
            let local = try workspace.url(for: path)
            nodes[path] = WriteNode(url: local, stamp: try WriteStamp(local), header: headers[path])
        }
        for value in deletions {
            let path = try worker.path(value)
            guard nodes[path] != nil || nodes.keys.contains(where: { $0.hasPrefix(path + "/") }) else {
                throw ArchiveError.invalidPath(path)
            }
            for key in Array(nodes.keys) where key == path || key.hasPrefix(path + "/") { nodes.removeValue(forKey: key) }
        }
        let base = prefix.isEmpty ? "" : try worker.path(prefix)
        for source in additions {
            try worker.validateSource(source, against: target)
            try worker.add(source, path: base.isEmpty ? source.lastPathComponent : base + "/" + source.lastPathComponent,
                           to: &nodes, policy: policy)
        }
        for key in replacements.keys.sorted() {
            let path = try worker.path(key)
            guard let prior = nodes[path], prior.stamp.regular else { throw ArchiveError.invalidPath(path) }
            let source = replacements[key]!
            try worker.validateSource(source, against: target)
            let stamp = try WriteStamp(source)
            guard stamp.regular else { throw ArchiveError.unsafeEntry(source.path) }
            nodes[path] = WriteNode(url: source, stamp: stamp, header: prior.header)
        }
        return try worker.commit(nodes, to: target, format: snapshot.format, original: original, snapshot: snapshot)
    }
}

private struct WriteStamp: Equatable {
    let device: dev_t, inode: ino_t, mode: mode_t
    let size: Int64
    let modified: timespec, changed: timespec
    let uid: uid_t, gid: gid_t
    var directory: Bool { mode & S_IFMT == S_IFDIR }
    var regular: Bool { mode & S_IFMT == S_IFREG }
    init(_ url: URL) throws {
        guard url.isFileURL else { throw ArchiveError.invalidPath(url.absoluteString) }
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw ArchiveWriteError.io("Не удалось прочитать «\(url.path)»: \(String(cString: strerror(errno)))") }
        device = value.st_dev; inode = value.st_ino; mode = value.st_mode; size = value.st_size
        modified = value.st_mtimespec; changed = value.st_ctimespec; uid = value.st_uid; gid = value.st_gid
    }
    init(fd: Int32) throws {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw ArchiveWriteError.io(String(cString: strerror(errno))) }
        device = value.st_dev; inode = value.st_ino; mode = value.st_mode; size = value.st_size
        modified = value.st_mtimespec; changed = value.st_ctimespec; uid = value.st_uid; gid = value.st_gid
    }
    func sameObject(_ other: Self) -> Bool { device == other.device && inode == other.inode }
    static func optional(_ url: URL) throws -> WriteStamp? {
        var value = stat()
        if lstat(url.path, &value) != 0 {
            if errno == ENOENT { return nil }
            throw ArchiveWriteError.io(String(cString: strerror(errno)))
        }
        return try WriteStamp(url)
    }
    static func == (a: Self, b: Self) -> Bool {
        a.sameAfterRename(b) && a.changed.tv_sec == b.changed.tv_sec && a.changed.tv_nsec == b.changed.tv_nsec
    }
    func sameAfterRename(_ other: Self) -> Bool {
        device == other.device && inode == other.inode && mode == other.mode && size == other.size &&
        modified.tv_sec == other.modified.tv_sec && modified.tv_nsec == other.modified.tv_nsec
    }
}
private final class WriteHeader {
    let raw: OpaquePointer
    init(_ raw: OpaquePointer) { self.raw = raw }
    deinit { archive_entry_free(raw) }
}
private struct WriteNode {
    let url: URL
    let stamp: WriteStamp
    let header: WriteHeader?
}
private final class ArchiveWriteWorker {
    let cancellation: TransferCancellation
    let progress: (ArchiveProgress) -> Void
    let fm = FileManager.default
    init(_ cancellation: TransferCancellation, _ progress: @escaping (ArchiveProgress) -> Void) {
        self.cancellation = cancellation; self.progress = progress
    }
    func check() throws { if cancellation.isCancelled { throw ArchiveError.cancelled } }
    func destination(_ url: URL) throws -> URL {
        guard url.isFileURL, !url.lastPathComponent.isEmpty else { throw ArchiveError.invalidPath(url.absoluteString) }
        let parent = url.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath()
        guard try WriteStamp(parent).directory else { throw ArchiveError.invalidPath(parent.path) }
        return parent.appendingPathComponent(url.lastPathComponent)
    }
    func validateSource(_ source: URL, against target: URL) throws {
        let stamp = try WriteStamp(source)
        let resolved = source.standardizedFileURL.resolvingSymlinksInPath().path
        let destination = target.standardizedFileURL.path
        if resolved == destination || (stamp.directory && destination.hasPrefix(resolved == "/" ? "/" : resolved + "/")) {
            throw ArchiveError.unsafeEntry(source.path)
        }
        if let existing = try WriteStamp.optional(target), stamp.device == existing.device && stamp.inode == existing.inode {
            throw ArchiveError.unsafeEntry(source.path)
        }
    }
    func path(_ value: String) throws -> String {
        let value = value.hasSuffix("/") ? String(value.dropLast()) : value
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\"), !value.contains(":"),
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              components.count <= ArchiveLimits.default.maximumPathDepth,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw ArchiveError.invalidPath(value) }
        return value
    }
    func add(_ source: URL, path proposed: String, to nodes: inout [String: WriteNode], policy: ArchiveOverwritePolicy) throws {
        try check()
        let name = try path(proposed)
        let stamp = try WriteStamp(source)
        guard stamp.regular || stamp.directory else { throw ArchiveError.unsafeEntry(source.path) }
        if (nodes[name] != nil && !(nodes[name]!.stamp.directory && stamp.directory)) ||
            (!stamp.directory && nodes.keys.contains(where: { $0.hasPrefix(name + "/") })) {
            switch policy {
            case .error: throw ArchiveWriteError.conflict(name)
            case .skip: return
            case .replace:
                for key in Array(nodes.keys) where key == name || key.hasPrefix(name + "/") { nodes.removeValue(forKey: key) }
            }
        }
        for ancestor in ancestors(name) where nodes[ancestor]?.stamp.regular == true { throw ArchiveWriteError.conflict(ancestor) }
        guard nodes.count < ArchiveLimits.default.maximumEntries || nodes[name] != nil,
              stamp.directory || stamp.size <= ArchiveLimits.default.maximumEntryBytes else {
            throw ArchiveError.limitExceeded("число элементов или размер файла")
        }
        nodes[name] = WriteNode(url: source, stamp: stamp, header: nil)
        if stamp.directory {
            for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try add(child, path: name + "/" + child.lastPathComponent, to: &nodes, policy: policy)
            }
        }
        guard try WriteStamp(source) == stamp else { throw ArchiveWriteError.sourceChanged(source.path) }
    }
    func ancestors(_ path: String) -> [String] {
        var components = path.split(separator: "/").map(String.init), result: [String] = []
        while components.count > 1 { components.removeLast(); result.append(components.joined(separator: "/")) }
        return result
    }
    func message(_ archive: OpaquePointer) -> ArchiveWriteError {
        ArchiveWriteError.io(archive_error_string(archive).map { String(cString: $0) } ?? "Ошибка записи архива.")
    }
    func headers(_ snapshot: ArchiveSnapshot) throws -> [String: WriteHeader] {
        try snapshot.verifyCurrent()
        guard let reader = archive_read_new() else { throw ArchiveWriteError.io("Не удалось создать читатель архива.") }
        defer { archive_read_free(reader) }
        archive_read_support_format_zip(reader); archive_read_support_format_tar(reader); archive_read_support_filter_all(reader)
        guard archive_read_open_filename(reader, snapshot.sourceURL.path, 65536) == ARCHIVE_OK else { throw message(reader) }
        var result: [String: WriteHeader] = [:], entry: OpaquePointer?
        while true {
            try check()
            let status = archive_read_next_header(reader, &entry)
            if status == ARCHIVE_EOF { break }
            guard status == ARCHIVE_OK, let entry, let raw = archive_entry_pathname_utf8(entry),
                  let clone = archive_entry_clone(entry) else { throw message(reader) }
            let header = WriteHeader(clone)
            let name = try path(String(cString: raw))
            guard archive_entry_is_encrypted(entry) == 0 else { throw ArchiveWriteError.encryptedReadOnly }
            guard archive_entry_filetype(entry) == S_IFREG || archive_entry_filetype(entry) == S_IFDIR,
                  archive_entry_symlink(entry) == nil, archive_entry_hardlink(entry) == nil else { throw ArchiveError.unsafeEntry(name) }
            // Filtered TAR must retain its compression; this writer intentionally supports plain TAR only.
            guard archive_filter_code(reader, 0) == ARCHIVE_FILTER_NONE else { throw ArchiveError.unsupportedFormat }
            result[name] = header
            guard archive_read_data_skip(reader) == ARCHIVE_OK else { throw message(reader) }
        }
        try snapshot.verifyCurrent()
        return result
    }
    func commit(_ nodes: [String: WriteNode], to target: URL, format: ArchiveFormat,
                original: WriteStamp?, snapshot: ArchiveSnapshot?) throws -> ArchiveSnapshot {
        try check()
        var byteTotal: Int64 = 0
        for node in nodes.values where node.stamp.regular {
            guard node.stamp.size <= ArchiveLimits.default.maximumTotalBytes - byteTotal else { throw ArchiveError.limitExceeded("общий размер") }
            byteTotal += node.stamp.size
        }
        let stage = target.deletingLastPathComponent().appendingPathComponent(".far-archive-\(UUID().uuidString)")
        let fd = Darwin.open(stage.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ArchiveWriteError.io(String(cString: strerror(errno))) }
        var removeStage = true
        var cleanupIdentity = try WriteStamp(fd: fd)
        defer {
            Darwin.close(fd)
            if removeStage, let current = try? WriteStamp(stage), current.sameObject(cleanupIdentity) { _ = Darwin.unlink(stage.path) }
        }
        try write(nodes, format: format, fd: fd)
        guard fsync(fd) == 0 else { throw ArchiveWriteError.io(String(cString: strerror(errno))) }
        let verified = try ArchiveReader.open(stage, cancellation: cancellation, onProgress: progress)
        let expected = Set(nodes.keys)
        guard Set(verified.entries.map(\.path)) == expected else { throw ArchiveWriteError.io("Проверка записанного архива не пройдена.") }
        let proof = try ArchiveReader.extract(verified, cancellation: cancellation, onProgress: progress)
        defer { proof.cleanup() }
        for (name, node) in nodes where node.stamp.regular {
            try equalBytes(node.url, try proof.url(for: name), stamp: node.stamp)
        }
        try check()
        for node in nodes.values where node.header == nil { guard try WriteStamp(node.url) == node.stamp else { throw ArchiveWriteError.sourceChanged(node.url.path) } }
        if let original {
            try snapshot?.verifyCurrent()
            guard try WriteStamp(target) == original else { throw ArchiveError.changedArchive }
            let metadataFlags = copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW_SRC | COPYFILE_NOFOLLOW_DST)
            guard copyfile(target.path, stage.path, nil, metadataFlags) == 0 else { throw ArchiveWriteError.io(String(cString: strerror(errno))) }
            guard try WriteStamp(target) == original else { throw ArchiveError.changedArchive }
            guard fsync(fd) == 0 else { throw ArchiveWriteError.io(String(cString: strerror(errno))) }
            try check()
            let prepared = try WriteStamp(fd: fd)
            guard try WriteStamp(stage) == prepared else { throw ArchiveError.changedArchive }
            // Atomic exchange retains the previous archive until its identity has been verified.
            guard renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, target.path, UInt32(RENAME_SWAP)) == 0 else { throw ArchiveWriteError.io(String(cString: strerror(errno))) }
            removeStage = false
            guard let swapped = try? WriteStamp(stage), original.sameAfterRename(swapped),
                  let published = try? WriteStamp(target), prepared.sameAfterRename(published) else {
                if renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, target.path, UInt32(RENAME_SWAP)) == 0 { removeStage = true }
                else { throw ArchiveWriteError.io("Архив изменился во время сохранения. Резервный файл оставлен: «\(stage.path)».") }
                throw ArchiveError.changedArchive
            }
            cleanupIdentity = original
            removeStage = true
        } else {
            // link() is exclusive and cannot overwrite a destination created during the operation.
            let prepared = try WriteStamp(fd: fd)
            guard try WriteStamp(stage) == prepared else { throw ArchiveError.changedArchive }
            guard Darwin.link(stage.path, target.path) == 0 else {
                if errno == EEXIST { throw ArchiveWriteError.conflict(target.path) }
                throw ArchiveWriteError.io(String(cString: strerror(errno)))
            }
            guard let published = try? WriteStamp(target), prepared.sameAfterRename(published),
                  let temporary = try? WriteStamp(stage), temporary.sameObject(prepared) else { throw ArchiveError.changedArchive }
            // Unlinking this temporary hard link changes the published inode's ctime.
            // Capture the returned snapshot only after that final metadata change.
            guard Darwin.unlink(stage.path) == 0 else { throw ArchiveWriteError.io(String(cString: strerror(errno))) }
            removeStage = false
        }
        return try ArchiveReader.open(target)
    }
    func write(_ nodes: [String: WriteNode], format: ArchiveFormat, fd: Int32) throws {
        guard let writer = archive_write_new() else { throw ArchiveWriteError.io("Не удалось создать архив.") }
        defer { archive_write_free(writer) }
        let configured = format == .zip ? archive_write_set_format_zip(writer) : archive_write_set_format_pax_restricted(writer)
        guard configured == ARCHIVE_OK else { throw message(writer) }
        // ZIP's UTF-8 flag otherwise depends on the process locale, even when
        // archive_entry_set_pathname_utf8 supplies UTF-8 bytes. Set an explicit
        // output charset without changing the locale of the application.
        if format == .zip {
            guard archive_write_set_format_option(writer, "zip", "hdrcharset", "UTF-8") == ARCHIVE_OK else { throw message(writer) }
        }
        guard archive_write_open_fd(writer, fd) == ARCHIVE_OK else { throw message(writer) }
        var buffer = [UInt8](repeating: 0, count: 65536)
        let total = nodes.values.filter { $0.stamp.regular }.reduce(Int64(0)) { $0 + $1.stamp.size }
        var completedBytes: Int64 = 0, completedItems = 0
        for name in nodes.keys.sorted() {
            try check()
            let node = nodes[name]!
            progress(ArchiveProgress(currentPath: name, completedBytes: completedBytes, totalBytes: total, completedItems: completedItems, totalItems: nodes.count))
            try check()
            guard try WriteStamp(node.url) == node.stamp else { throw ArchiveWriteError.sourceChanged(node.url.path) }
            guard let entry = node.header.flatMap({ archive_entry_clone($0.raw) }) ?? archive_entry_new() else { throw message(writer) }
            defer { archive_entry_free(entry) }
            archive_entry_set_pathname_utf8(entry, name)
            archive_entry_set_filetype(entry, node.stamp.directory ? UInt32(S_IFDIR) : UInt32(S_IFREG))
            archive_entry_set_size(entry, node.stamp.directory ? 0 : node.stamp.size)
            if node.header == nil {
                archive_entry_set_perm(entry, node.stamp.mode & 0o7777)
                archive_entry_set_uid(entry, Int64(node.stamp.uid)); archive_entry_set_gid(entry, Int64(node.stamp.gid))
                archive_entry_set_mtime(entry, node.stamp.modified.tv_sec, node.stamp.modified.tv_nsec)
            }
            guard archive_write_header(writer, entry) == ARCHIVE_OK else { throw message(writer) }
            if node.stamp.regular {
                let input = Darwin.open(node.url.path, O_RDONLY | O_NOFOLLOW)
                guard input >= 0 else { throw ArchiveWriteError.io(String(cString: strerror(errno))) }
                defer { Darwin.close(input) }
                var count: Int64 = 0
                while true {
                    try check()
                    let amount = Darwin.read(input, &buffer, buffer.count)
                    guard amount >= 0 else { throw ArchiveWriteError.io(String(cString: strerror(errno))) }
                    if amount == 0 { break }
                    count += Int64(amount)
                    guard count <= node.stamp.size else { throw ArchiveWriteError.sourceChanged(node.url.path) }
                    let written = buffer.withUnsafeBytes { archive_write_data(writer, $0.baseAddress, amount) }
                    guard written == amount else { throw message(writer) }
                    completedBytes += Int64(amount)
                    progress(ArchiveProgress(currentPath: name, completedBytes: completedBytes, totalBytes: total, completedItems: completedItems, totalItems: nodes.count))
                }
                guard count == node.stamp.size, try WriteStamp(node.url) == node.stamp else { throw ArchiveWriteError.sourceChanged(node.url.path) }
            }
            guard archive_write_finish_entry(writer) == ARCHIVE_OK else { throw message(writer) }
            completedItems += 1
        }
        guard archive_write_close(writer) == ARCHIVE_OK else { throw message(writer) }
    }
    func equalBytes(_ source: URL, _ result: URL, stamp: WriteStamp) throws {
        let sourceFD = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceFD >= 0 else { throw ArchiveWriteError.sourceChanged(source.path) }
        let a = FileHandle(fileDescriptor: sourceFD, closeOnDealloc: true)
        defer { try? a.close() }
        let resultFD = Darwin.open(result.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard resultFD >= 0 else { throw ArchiveWriteError.io("Не удалось проверить записанный файл.") }
        let b = FileHandle(fileDescriptor: resultFD, closeOnDealloc: true)
        defer { try? b.close() }
        while true {
            try check()
            let first = try a.read(upToCount: 65536) ?? Data(), second = try b.read(upToCount: 65536) ?? Data()
            guard first == second else { throw ArchiveWriteError.io("Данные записанного архива не совпадают: «\(source.lastPathComponent)».") }
            if first.isEmpty { break }
        }
        guard try WriteStamp(source) == stamp else { throw ArchiveWriteError.sourceChanged(source.path) }
    }
}
