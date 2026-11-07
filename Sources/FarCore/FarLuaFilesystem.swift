import Foundation
import Darwin

/// Native file operations exposed through LuaFAR's return conventions. Paths
/// are resolved relative to the command workspace on macOS.
public enum FarLuaFilesystem {
    private static let operations: Set<String> = [
        "win.CopyFile", "win.MoveFile", "win.RenameFile", "win.DeleteFile", "win.CreateDir", "win.RemoveDir", "win.GetFileInfo",
        "win.GetFileAttr", "far.GetDirList", "mf.fexist", "mf.fattr", "mf.testfolder"
    ]

    public static func invoke(_ operation: String, arguments: [FarLuaValue], directory: URL) async throws -> [FarLuaValue]? {
        guard operations.contains(operation) else { return nil }
        let worker = Task.detached(priority: .userInitiated) { try run(operation, arguments: arguments, directory: directory) }
        return try await withTaskCancellationHandler(operation: {
            try await worker.value
        }, onCancel: {
            worker.cancel()
        })
    }

    private static func run(_ operation: String, arguments: [FarLuaValue], directory: URL) throws -> [FarLuaValue] {
        func argument(_ index: Int) -> FarLuaValue { arguments.indices.contains(index) ? arguments[index] : .nilValue }
        func path(_ index: Int) throws -> URL {
            guard let value = argument(index).string, !value.isEmpty, !value.utf8.contains(0) else { throw POSIXError(.EINVAL) }
            return (value.hasPrefix("/") ? URL(fileURLWithPath: value) : directory.appendingPathComponent(value)).standardizedFileURL
        }
        func truthy(_ value: FarLuaValue) -> Bool { value != .nilValue && value != .bool(false) }
        do {
            try Task.checkCancellation()
            switch operation {
            case "win.GetFileInfo", "win.GetFileAttr", "mf.fexist", "mf.fattr":
                let value = try firstMatch(try path(0), wildcards: operation != "win.GetFileAttr")
                switch operation {
                case "win.GetFileInfo": return [.table(value.fields(fileName: value.url.lastPathComponent, panelItem: false))]
                case "win.GetFileAttr": return [.string(value.attributeText)]
                case "mf.fexist": return [.bool(true)]
                default: return [.integer(Int64(value.attributeBits))]
                }
            case "mf.testfolder":
                guard argument(0).string != nil else { return [.integer(-2)] }
                return [.integer(try testFolder(path(0)))]
            case "far.GetDirList":
                return [.array(try list(path(0)))]
            case "win.CopyFile":
                try copy(path(0), to: path(1), replace: !truthy(argument(2)), synchronize: false)
            case "win.MoveFile", "win.RenameFile":
                let options = argument(2).string ?? ""
                guard !options.contains("d") else { throw POSIXError(.ENOTSUP) }
                try move(path(0), to: path(1), replace: options.contains("r"),
                         crossVolume: options.contains("c"), synchronize: options.contains("w"))
            case "win.DeleteFile":
                let target = try path(0)
                guard unlink(target.path) == 0 else { throw systemError() }
            case "win.CreateDir":
                let flags = argument(1).string ?? (truthy(argument(1)) ? "t" : "")
                if try !createDirectory(path(0), intermediate: !flags.contains("o"), tolerant: flags.contains("t")) {
                    return [.nilValue, .string("directory already exists")]
                }
            case "win.RemoveDir":
                let target = try path(0)
                guard rmdir(target.path) == 0 else { throw systemError() }
            default: preconditionFailure("Unregistered Lua filesystem operation")
            }
            return [.bool(true)]
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            switch operation {
            case "mf.fexist": return [.bool(false)]
            case "mf.fattr": return [.integer(-1)]
            case "mf.testfolder": return [.integer(-2)]
            case "far.GetDirList", "win.GetFileAttr": return [.nilValue]
            default:
                let error = error as NSError
                return [.nilValue, .string(error.localizedDescription), .integer(Int64(error.code))]
            }
        }
    }

    private struct File {
        let url: URL
        let info: stat
        var isDirectory: Bool { info.st_mode & S_IFMT == S_IFDIR }
        var isLink: Bool { info.st_mode & S_IFMT == S_IFLNK }
        var isReadOnly: Bool { info.st_mode & (S_IWUSR | S_IWGRP | S_IWOTH) == 0 }
        var isHidden: Bool { url.lastPathComponent.hasPrefix(".") || info.st_flags & UInt32(UF_HIDDEN) != 0 }
        var attributeBits: Int32 {
            (isDirectory ? 16 : 32) | (isLink ? 1024 : 0) | (isReadOnly ? 1 : 0) | (isHidden ? 2 : 0)
        }
        var attributeText: String {
            (isDirectory ? "d" : "a") + (isLink ? "l" : "") + (isReadOnly ? "r" : "") + (isHidden ? "h" : "")
        }

        func fields(fileName: String, panelItem: Bool) -> [String: FarLuaValue] {
            // LuaFAR's default FILETIME is milliseconds since 1601.
            func time(_ value: timespec) -> FarLuaValue {
                .number((Double(value.tv_sec) + 11_644_473_600) * 1000 + Double(value.tv_nsec) / 1_000_000)
            }
            var fields: [String: FarLuaValue] = [
                "FileName": .string(fileName), "AlternateFileName": .string(""), "FileSize": .integer(isDirectory ? 0 : info.st_size),
                "FileAttributes": .string(attributeText), "CreationTime": time(info.st_birthtimespec),
                "LastAccessTime": time(info.st_atimespec), "LastWriteTime": time(info.st_mtimespec)
            ]
            if panelItem {
                fields["Flags"] = .integer(0)
                fields["ChangeTime"] = time(info.st_ctimespec)
                fields["AllocationSize"] = .integer(info.st_blocks * 512)
                fields["NumberOfLinks"] = .integer(Int64(info.st_nlink))
            }
            return fields
        }
    }

    private static func file(_ url: URL) throws -> File {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw systemError() }
        return File(url: url, info: info)
    }

    private static func firstMatch(_ url: URL, wildcards: Bool) throws -> File {
        let pattern = url.lastPathComponent
        guard wildcards, pattern.contains("*") || pattern.contains("?") else { return try file(url) }
        let parent = url.deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        for name in names.sorted() {
            try Task.checkCancellation()
            if wildcard(pattern, matches: name) {
                do { return try file(parent.appendingPathComponent(name)) }
                catch let error as POSIXError where error.code == .ENOENT { continue }
            }
        }
        return try file(url)
    }

    private static func wildcard(_ pattern: String, matches name: String) -> Bool {
        let locale = Locale(identifier: "en_US_POSIX")
        let pattern = Array((pattern == "*.*" ? "*" : pattern).folding(options: .caseInsensitive, locale: locale).utf16)
        let name = Array(name.folding(options: .caseInsensitive, locale: locale).utf16)
        var p = 0, n = 0, star: Int?, retried = 0
        while n < name.count {
            if p < pattern.count, pattern[p] == 42 {
                star = p; retried = n; p += 1
            } else if p < pattern.count, pattern[p] == 63 || pattern[p] == name[n] {
                p += 1; n += 1
            } else if let star {
                p = star + 1; retried += 1; n = retried
            } else { return false }
        }
        return pattern[p...].allSatisfy { $0 == 42 }
    }

    private static func list(_ directory: URL) throws -> [FarLuaValue] {
        var info = stat()
        guard stat(directory.path, &info) == 0 else { throw systemError() }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw POSIXError(.ENOTDIR) }
        var issue: Error?
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil, options: [],
            errorHandler: { _, error in issue = error; return false }) else { throw POSIXError(.ENOTDIR) }
        var result: [FarLuaValue] = []
        while let url = files.nextObject() as? URL {
            try Task.checkCancellation()
            guard result.count < 100_000 else { throw POSIXError(.E2BIG) }
            let value = try file(url)
            result.append(.table(value.fields(fileName: url.path, panelItem: true)))
        }
        if let issue { throw issue }
        return result
    }

    private static func testFolder(_ path: URL) throws -> Int64 {
        var info = stat()
        guard stat(path.path, &info) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return 2 }
            return errno == EACCES || errno == EPERM ? -1 : -2
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { return 2 }
        guard let directory = opendir(path.path) else { return -1 }
        defer { closedir(directory) }
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { return 1 }
        }
        return errno == 0 ? 0 : -1
    }

    private static func copy(_ source: URL, to destination: URL, replace: Bool, synchronize: Bool) throws {
        let input = open(source.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw systemError() }
        defer { close(input) }
        var sourceInfo = stat(), destinationInfo = stat()
        guard fstat(input, &sourceInfo) == 0 else { throw systemError() }
        guard sourceInfo.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EINVAL) }
        if !replace, lstat(destination.path, &destinationInfo) == 0 { throw POSIXError(.EEXIST) }
        if stat(destination.path, &destinationInfo) == 0,
           sourceInfo.st_dev == destinationInfo.st_dev, sourceInfo.st_ino == destinationInfo.st_ino {
            throw POSIXError(.EINVAL)
        }
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".far-lua-copy-" + UUID().uuidString)
        let output = open(stage.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard output >= 0 else { throw systemError() }
        var committed = false
        defer {
            close(output)
            if !committed { unlink(stage.path) }
        }
        guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else { throw systemError() }
        var current = stat()
        guard fstat(input, &current) == 0 else { throw systemError() }
        guard sameFileVersion(sourceInfo, current) else { throw POSIXError(.ESTALE) }
        if synchronize && fsync(output) != 0 { throw systemError() }
        try Task.checkCancellation()
        try rename(stage, to: destination, replace: replace)
        committed = true
    }

    private static func rename(_ source: URL, to destination: URL, replace: Bool) throws {
        let result = replace ? Darwin.rename(source.path, destination.path)
            : renameatx_np(AT_FDCWD, source.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL))
        guard result == 0 else { throw systemError() }
    }

    private static func move(_ source: URL, to destination: URL, replace: Bool, crossVolume: Bool, synchronize: Bool) throws {
        do { try rename(source, to: destination, replace: replace) }
        catch let error as POSIXError where error.code == .EXDEV && crossVolume {
            let original = try file(source)
            guard original.info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.ENOTSUP) }
            try copy(source, to: destination, replace: replace, synchronize: synchronize)
            let current = try file(source)
            guard sameFileVersion(original.info, current.info) else {
                throw POSIXError(.ESTALE)
            }
            guard unlink(source.path) == 0 else { throw systemError() }
        }
    }

    private static func sameFileVersion(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino && first.st_size == second.st_size
            && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
            && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }

    private static func createDirectory(_ target: URL, intermediate: Bool, tolerant: Bool) throws -> Bool {
        var pending: [URL] = [target]
        var current = target
        var info = stat()
        if stat(target.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR { return tolerant }
        if intermediate {
            while current.path != "/" {
                current = current.deletingLastPathComponent()
                if stat(current.path, &info) == 0 { break }
                if errno != ENOENT { throw systemError() }
                pending.append(current)
            }
        }
        var created: [URL] = []
        do {
            for directory in pending.reversed() {
                try Task.checkCancellation()
                if mkdir(directory.path, mode_t(0o777)) == 0 { created.append(directory); continue }
                let error = systemError()
                if error.code == .EEXIST, stat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR {
                    if directory != target || tolerant { continue }
                    return false
                }
                throw error
            }
            return true
        } catch {
            for directory in created.reversed() { _ = rmdir(directory.path) }
            throw error
        }
    }

    private static func systemError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
