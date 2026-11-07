import Foundation
import Darwin

public enum SSHConfigurationError: LocalizedError, Equatable {
    case unreadableFile(String)
    case malformed(file: String, line: Int, reason: String)
    case unsupported(String)
    case limitExceeded(String)
    case includeCycle(String)
    case jumpCycle(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableFile(let file): return "Не удалось прочитать SSH config: \(file)."
        case .malformed(let file, let line, let reason): return "SSH config, \(file):\(line): \(reason)"
        case .unsupported(let reason): return "Импорт SSH config: \(reason)"
        case .limitExceeded(let reason): return "Превышен предел импорта SSH config: \(reason)"
        case .includeCycle(let file): return "Циклический Include в SSH config: \(file)."
        case .jumpCycle(let host): return "Циклическая цепочка SSH-шлюзов: \(host)."
        }
    }
}

/// A bounded, data-only import, never an invocation of `ssh -G` or a shell.
///
/// Host/HostName/User/Port/IdentityFile/ProxyJump and Include are supported. Include
/// paths are relative to ~/.ssh for ~/.ssh/config, or to the selected config's
/// directory for portable config bundles (also for nested includes). Globs are
/// processed in lexical order. `~` and `~/` refer to the current user's home;
/// other users' homes and environment expansion are intentionally unsupported.
/// Include accepts %%/%d/%u; HostName accepts %%/%h; IdentityFile accepts
/// %%/%d/%h/%n/%p/%r/%u; ProxyJump accepts %%/%h/%n/%p/%r.
///
/// Match supports only all, host, originalhost, user and localuser in one pass.
/// Other criteria and unrepresented routing/authentication/security directives fail closed.
/// Multiple distinct IdentityFile values also fail, because OpenSSH accumulates
/// them while a connection profile stores one key. Only presentation, session and
/// keepalive hints in `ignoredHints` below may be omitted during import. System
/// configuration and default key discovery are left to the isolated SFTP runtime.
/// An explicit IdentitiesOnly=yes requires an IdentityFile; IdentitiesOnly=no
/// together with an IdentityFile cannot be represented by the current runtime.
/// UseKeychain=yes and disabled forwarding/other authentication methods are
/// accepted when they match the runtime's fixed policy. AddKeysToAgent=no is
/// supported; automatic agent mutation (yes/ask/confirm) is not imported.
public enum SSHConfiguration {
    public static func importConnection(alias: String, from url: URL, username: String = NSUserName()) throws -> NetworkConnection {
        try validateAlias(alias)
        guard !username.isEmpty, !username.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            throw SSHConfigurationError.unsupported("Укажите непустое имя локального пользователя без пробелов и управляющих символов.")
        }
        let importer = Importer(url: url, localUsername: username)
        let resolved = try importer.resolve(alias: alias, ancestors: [])
        let profile = NetworkConnection(name: alias, kind: .sftp, host: resolved.host.host, port: resolved.host.port,
                                        username: resolved.host.username, privateKeyPath: resolved.host.privateKeyPath,
                                        timeoutSeconds: resolved.timeout, sftpJumpHosts: resolved.jumps)
        try profile.validate()
        return profile
    }

    private static func validateAlias(_ alias: String) throws {
        guard !alias.isEmpty, alias.utf8.count <= 253, !alias.hasPrefix("-"),
              alias.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:").contains($0) }) else {
            throw SSHConfigurationError.unsupported("Укажите SSH-псевдоним без пробелов, путей и параметров командной строки.")
        }
    }

    private struct Directive {
        let name: String
        let arguments: [String]
        let file: URL
        let line: Int
        func malformed(_ reason: String) -> SSHConfigurationError {
            .malformed(file: file.path, line: line, reason: reason)
        }
        func single() throws -> String {
            guard arguments.count == 1, let value = arguments.first, !value.isEmpty else {
                throw malformed("\(name) требует одно непустое значение.")
            }
            return value
        }
    }

    private struct Options {
        var first: [String: String] = [:]
        var identities: [String] = []
    }
    private struct Resolved {
        var host: SFTPJumpHost
        var jumps: [SFTPJumpHost]
        var timeout: Double
    }
    private struct JumpAddress {
        var alias: String
        var username: String?
        var port: Int?
    }

    private final class Importer {
        let url: URL
        let includeDirectory: URL
        let localUsername: String
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var cache: [URL: [Directive]] = [:]
        var totalBytes = 0
        var evaluations = 0
        static let maxBytes = 1_048_576
        // These do not select destinations, identities or host-key policy. The
        // app controls its own SFTP session, keepalive, UI and logging behavior.
        static let ignoredHints: Set<String> = [
            "loglevel", "visualhostkey", "serveraliveinterval", "serveralivecountmax",
            "tcpkeepalive", "ipqos", "compression", "requesttty", "escapechar",
            "sendenv", "setenv", "enableescapecommandline"
        ]
        static let fixedPolicy: [String: String] = [
            "usekeychain": "yes", "addkeystoagent": "no", "forwardagent": "no",
            "forwardx11": "no", "forwardx11trusted": "no", "permitlocalcommand": "no",
            "passwordauthentication": "no", "pubkeyauthentication": "yes",
            "kbdinteractiveauthentication": "no", "challengeresponseauthentication": "no",
            "gssapiauthentication": "no", "hostbasedauthentication": "no", "canonicalizehostname": "no"
        ]

        init(url: URL, localUsername: String) {
            self.url = url.standardizedFileURL
            self.includeDirectory = url.standardizedFileURL.deletingLastPathComponent()
            self.localUsername = localUsername
        }

        func resolve(alias: String, username: String? = nil, port: Int? = nil, ancestors: [String], inheritProxyJump: Bool = true) throws -> Resolved {
            let normalizedAlias = alias.lowercased()
            guard !inheritProxyJump || !ancestors.contains(normalizedAlias) else { throw SSHConfigurationError.jumpCycle(alias) }
            guard ancestors.count <= 4 else { throw SSHConfigurationError.limitExceeded("не более четырёх SSH-шлюзов") }
            var options = Options()
            try evaluate(file: url, alias: alias, userOverride: username, options: &options, stack: [])
            for (name, requiredValue) in Self.fixedPolicy {
                if let value = options.first[name], value.lowercased() != requiredValue {
                    throw SSHConfigurationError.unsupported("\(name)=\(value) не соответствует политике SFTP; поддерживается только \(requiredValue).")
                }
            }
            let host = try expand(options.first["hostname"] ?? alias, values: ["h": alias], context: "HostName")
            let user = username ?? options.first["user"] ?? localUsername
            guard !user.isEmpty, !user.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
                throw SSHConfigurationError.unsupported("User должен быть непустым и не содержать пробелы или управляющие символы.")
            }
            let resolvedPort = try port ?? integer(options.first["port"] ?? "22", name: "Port", range: 1...65535)
            let timeout = try integer(options.first["connecttimeout"] ?? "30", name: "ConnectTimeout", range: 1...600)
            let tokens: [Character: String] = ["d": home, "h": host, "n": alias, "p": String(resolvedPort), "r": user, "u": localUsername]
            let identities = try options.identities.map { try expandHome(expand($0, values: tokens, context: "IdentityFile")) }
            guard Set(identities).count <= 1 else { throw SSHConfigurationError.unsupported("Несколько IdentityFile нельзя представить одним ключом профиля.") }
            if let key = identities.first, key == "none" || !key.hasPrefix("/") {
                throw SSHConfigurationError.unsupported("IdentityFile требует абсолютный путь, ~/ или %d; значение none не поддерживается.")
            }
            if let only = options.first["identitiesonly"]?.lowercased() {
                guard only == "yes" || only == "no" else { throw SSHConfigurationError.unsupported("IdentitiesOnly требует yes или no.") }
                guard (only == "yes") == !identities.isEmpty else {
                    throw SSHConfigurationError.unsupported("Поддерживаются IdentitiesOnly=yes с IdentityFile либо IdentitiesOnly=no без явного ключа.")
                }
            }
            let endpoint = SFTPJumpHost(host: host, port: resolvedPort, username: user, privateKeyPath: identities.first)
            // Validate before expanding routes, including values introduced by tokens.
            try NetworkConnection(kind: .sftp, host: host, port: resolvedPort, username: user, privateKeyPath: identities.first).validate()
            var jumps: [SFTPJumpHost] = []
            if inheritProxyJump, let rawJump = options.first["proxyjump"], rawJump.lowercased() != "none" {
                let jumpTokens = tokens.filter { "hnpr".contains($0.key) }
                let value = try expand(rawJump, values: jumpTokens, context: "ProxyJump")
                let addresses = value.split(separator: ",", omittingEmptySubsequences: false)
                guard addresses.count <= 4 else { throw SSHConfigurationError.limitExceeded("не более четырёх SSH-шлюзов") }
                for (index, address) in addresses.enumerated() {
                    let parsed = try parseJump(String(address))
                    // OpenSSH turns a,b into `ssh -J a -W target b`: the
                    // command-line chain overrides b's own ProxyJump. Only the
                    // first gateway can inherit a route from its Host stanza.
                    let nested = try resolve(alias: parsed.alias, username: parsed.username, port: parsed.port, ancestors: ancestors + [normalizedAlias], inheritProxyJump: index == 0)
                    jumps.append(contentsOf: nested.jumps)
                    jumps.append(nested.host)
                    guard jumps.count <= 4 else { throw SSHConfigurationError.limitExceeded("не более четырёх SSH-шлюзов") }
                }
            }
            var endpoints: Set<String> = ["\(host.lowercased()):\(resolvedPort)"]
            for jump in jumps where !endpoints.insert("\(jump.host.lowercased()):\(jump.port)").inserted {
                throw SSHConfigurationError.jumpCycle(jump.host)
            }
            return Resolved(host: endpoint, jumps: jumps, timeout: Double(timeout))
        }

        func evaluate(file: URL, alias: String, userOverride: String?, options: inout Options, stack: [URL]) throws {
            let canonical = file.standardizedFileURL.resolvingSymlinksInPath()
            guard !stack.contains(canonical) else { throw SSHConfigurationError.includeCycle(canonical.path) }
            guard stack.count < 8 else { throw SSHConfigurationError.limitExceeded("глубина Include не более 8") }
            evaluations += 1
            guard evaluations <= 512 else { throw SSHConfigurationError.limitExceeded("слишком много Include или переходов между шлюзами") }
            var active = true
            for directive in try read(canonical) {
                if directive.name == "host" {
                    guard !directive.arguments.isEmpty else { throw directive.malformed("Host требует шаблон.") }
                    active = matches(alias, patterns: directive.arguments)
                    continue
                }
                if directive.name == "match" {
                    active = try evaluateMatch(directive, alias: alias, userOverride: userOverride, options: options)
                    continue
                }
                guard active else { continue }
                switch directive.name {
                case "include":
                    guard !directive.arguments.isEmpty else { throw directive.malformed("Include требует путь.") }
                    for argument in directive.arguments {
                        let path = try expandHome(expand(argument, values: ["d": home, "u": localUsername], context: "Include"))
                        for included in try includedFiles(path) {
                            try evaluate(file: included, alias: alias, userOverride: userOverride, options: &options, stack: stack + [canonical])
                        }
                    }
                case "hostname", "user", "port", "proxyjump", "connecttimeout", "identitiesonly":
                    let value = try directive.single()
                    if options.first[directive.name] == nil { options.first[directive.name] = value }
                case "identityfile":
                    options.identities.append(try directive.single())
                default:
                    if Self.fixedPolicy[directive.name] != nil {
                        let value = try directive.single()
                        if options.first[directive.name] == nil { options.first[directive.name] = value }
                        continue
                    }
                    guard Self.ignoredHints.contains(directive.name) else {
                        throw SSHConfigurationError.unsupported("Директива \(directive.name) (\(directive.file.lastPathComponent):\(directive.line)) не переносится в профиль. Удалите её из импортируемой копии или настройте подключение вручную; команды не выполнялись.")
                    }
                }
            }
        }

        func evaluateMatch(_ directive: Directive, alias: String, userOverride: String?, options: Options) throws -> Bool {
            var tokens = directive.arguments.makeIterator()
            guard let first = tokens.next() else { throw directive.malformed("Match требует условие.") }
            let initial = first.lowercased()
            if initial == "all" || initial == "!all" {
                guard tokens.next() == nil else { throw directive.malformed("Match all должно быть единственным условием.") }
                return initial == "all"
            }
            var current: String? = first
            var active = true
            while let token = current {
                let fields = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let firstField = fields.first, !firstField.isEmpty else { throw directive.malformed("Пустое условие Match.") }
                let key = firstField.lowercased()
                let negated = key.hasPrefix("!")
                let name = negated ? String(key.dropFirst()) : key
                let value: String
                switch name {
                case "host":
                    value = try expand(options.first["hostname"] ?? alias, values: ["h": alias], context: "HostName")
                case "originalhost": value = alias
                case "user": value = userOverride ?? options.first["user"] ?? localUsername
                case "localuser": value = localUsername
                default:
                    throw SSHConfigurationError.unsupported("Условие Match «\(name)» не поддерживается; команды не выполнялись.")
                }
                let argument = fields.count == 2 ? String(fields[1]) : tokens.next()
                guard let argument, !argument.isEmpty else { throw directive.malformed("Match \(name) требует шаблон.") }
                let patterns = argument.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                guard patterns.allSatisfy({ !$0.isEmpty && $0 != "!" && !$0.contains(where: \.isWhitespace) }) else {
                    throw directive.malformed("Match \(name) требует непустые шаблоны через запятую.")
                }
                let matched = matches(value, patterns: patterns, ignoreCase: name == "host" || name == "originalhost")
                active = active && (matched != negated)
                current = tokens.next()
            }
            return active
        }

        func read(_ file: URL) throws -> [Directive] {
            if let existing = cache[file] { return existing }
            guard cache.count < 64 else { throw SSHConfigurationError.limitExceeded("не более 64 файлов") }
            let values: URLResourceValues
            do { values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) }
            catch { throw SSHConfigurationError.unreadableFile(file.path) }
            guard values.isRegularFile == true else { throw SSHConfigurationError.unreadableFile(file.path) }
            guard (values.fileSize ?? 0) <= Self.maxBytes else { throw SSHConfigurationError.limitExceeded("общий размер не более 1 МиБ") }
            let data: Data
            do {
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                data = try handle.read(upToCount: Self.maxBytes + 1) ?? Data()
            } catch { throw SSHConfigurationError.unreadableFile(file.path) }
            totalBytes += data.count
            guard totalBytes <= Self.maxBytes else { throw SSHConfigurationError.limitExceeded("общий размер не более 1 МиБ") }
            guard var contents = String(data: data, encoding: .utf8), !contents.contains("\0") else {
                throw SSHConfigurationError.malformed(file: file.path, line: 1, reason: "Требуется UTF-8 без NUL.")
            }
            if contents.hasPrefix("\u{feff}") { contents.removeFirst() }
            let directives = try contents.components(separatedBy: .newlines).enumerated().compactMap { index, line in
                try parse(line, file: file, number: index + 1)
            }
            cache[file] = directives
            return directives
        }

        func includedFiles(_ path: String) throws -> [URL] {
            let absolute = path.hasPrefix("/") ? path : includeDirectory.appendingPathComponent(path).path
            var candidates: [URL] = [URL(fileURLWithPath: "/", isDirectory: true)]
            var inspected = 0
            for component in absolute.split(separator: "/") {
                let part = String(component)
                if part.contains(where: { "*?[".contains($0) }) {
                    var next: [URL] = []
                    for directory in candidates {
                        let entries: [URL]
                        do { entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
                        catch { throw SSHConfigurationError.unreadableFile(directory.path) }
                        inspected += entries.count
                        guard inspected <= 4096 else { throw SSHConfigurationError.limitExceeded("не более 4096 проверяемых путей Include") }
                        for entry in entries where fnmatch(part, entry.lastPathComponent, FNM_PERIOD) == 0 { next.append(entry) }
                    }
                    candidates = next
                } else {
                    candidates = candidates.map { $0.appendingPathComponent(part) }.filter { FileManager.default.fileExists(atPath: $0.path) }
                }
                guard candidates.count <= 64 else { throw SSHConfigurationError.limitExceeded("Include соответствует более чем 64 путям") }
            }
            return candidates.sorted { $0.path < $1.path }
        }

        func expandHome(_ value: String) throws -> String {
            if value == "~" { return home }
            if value.hasPrefix("~/") { return home + value.dropFirst() }
            guard !value.hasPrefix("~") else { throw SSHConfigurationError.unsupported("Разворачивание ~другого_пользователя не поддерживается.") }
            return value
        }

        func expand(_ value: String, values: [Character: String], context: String) throws -> String {
            guard !value.contains("${") else { throw SSHConfigurationError.unsupported("Переменные окружения в \(context) не поддерживаются.") }
            var result = ""
            var iterator = value.makeIterator()
            while let character = iterator.next() {
                if character != "%" { result.append(character); continue }
                guard let token = iterator.next() else { throw SSHConfigurationError.unsupported("Незавершённый токен % в \(context).") }
                if token == "%" { result.append("%") }
                else if let replacement = values[token] { result += replacement }
                else { throw SSHConfigurationError.unsupported("Токен %\(token) в \(context) не поддерживается.") }
            }
            guard result.utf8.count <= 16_384 else { throw SSHConfigurationError.limitExceeded("развёрнутое значение длиннее 16 КиБ") }
            return result
        }

        func integer(_ value: String, name: String, range: ClosedRange<Int>) throws -> Int {
            guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(value), range.contains(number) else {
                throw SSHConfigurationError.unsupported("\(name) должен быть целым числом \(range.lowerBound)–\(range.upperBound).")
            }
            return number
        }

        func parseJump(_ value: String) throws -> JumpAddress {
            var address = value
            if address.hasPrefix("ssh://") { address = String(address.dropFirst(6)) }
            guard !address.isEmpty else { throw SSHConfigurationError.unsupported("Пустой адрес ProxyJump.") }
            var user: String?
            if let at = address.firstIndex(of: "@") {
                user = String(address[..<at]); address = String(address[address.index(after: at)...])
                guard user?.isEmpty == false, !address.isEmpty, !address.contains("@") else { throw SSHConfigurationError.unsupported("Некорректный пользователь ProxyJump.") }
            }
            let host: String
            var port: Int?
            if address.hasPrefix("["), let end = address.firstIndex(of: "]") {
                host = String(address[address.index(after: address.startIndex)..<end])
                let suffix = String(address[address.index(after: end)...])
                if !suffix.isEmpty {
                    guard suffix.hasPrefix(":") else { throw SSHConfigurationError.unsupported("Некорректный адрес ProxyJump.") }
                    port = try integer(String(suffix.dropFirst()), name: "ProxyJump port", range: 1...65535)
                }
            } else {
                let parts = address.split(separator: ":", omittingEmptySubsequences: false)
                guard parts.count <= 2 else { throw SSHConfigurationError.unsupported("IPv6 в ProxyJump требует квадратные скобки.") }
                host = String(parts[0])
                if parts.count == 2 { port = try integer(String(parts[1]), name: "ProxyJump port", range: 1...65535) }
            }
            try validateAlias(host)
            return JumpAddress(alias: host, username: user, port: port)
        }
    }

    private static func matches(_ alias: String, patterns: [String], ignoreCase: Bool = true) -> Bool {
        let text = ignoreCase ? alias.lowercased() : alias
        var positive = false
        for pattern in patterns {
            let negative = pattern.hasPrefix("!")
            let value = negative ? String(pattern.dropFirst()) : pattern
            if wildcardMatch(text, pattern: ignoreCase ? value.lowercased() : value) {
                if negative { return false }
                positive = true
            }
        }
        return positive
    }

    // Host patterns only support * and ?. Avoid a regular expression here:
    // repeated wildcard fragments in an imported file must not cause unbounded
    // regex backtracking. Input hostnames and config lines are bounded as well.
    private static func wildcardMatch(_ value: String, pattern: String) -> Bool {
        let text = Array(value), glob = Array(pattern)
        var input = 0, cursor = 0, retryInput = 0
        var star: Int?
        while input < text.count {
            if cursor < glob.count && (glob[cursor] == "?" || glob[cursor] == text[input]) {
                input += 1; cursor += 1
            } else if cursor < glob.count && glob[cursor] == "*" {
                star = cursor; cursor += 1; retryInput = input
            } else if let lastStar = star {
                retryInput += 1; input = retryInput; cursor = lastStar + 1
            } else { return false }
        }
        while cursor < glob.count && glob[cursor] == "*" { cursor += 1 }
        return cursor == glob.count
    }

    private static func parse(_ line: String, file: URL, number: Int) throws -> Directive? {
        func malformed(_ reason: String) -> SSHConfigurationError { .malformed(file: file.path, line: number, reason: reason) }
        guard line.utf8.count <= 16_384 else { throw malformed("Строка длиннее 16 КиБ.") }
        guard !line.unicodeScalars.contains(where: { ($0.value < 32 && $0 != "\t") || $0.value == 127 }) else { throw malformed("Управляющие символы не поддерживаются.") }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        let keywordEnd = trimmed.firstIndex(where: { $0.isWhitespace || $0 == "=" }) ?? trimmed.endIndex
        let name = String(trimmed[..<keywordEnd]).lowercased()
        var remainder = String(trimmed[keywordEnd...]).trimmingCharacters(in: .whitespaces)
        if remainder.hasPrefix("=") { remainder = String(remainder.dropFirst()).trimmingCharacters(in: .whitespaces) }
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var started = false
        let characters = Array(remainder)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            // Match OpenSSH argv_split: only quotes, a backslash, and an
            // unquoted space are escapable. Unknown escapes stay literal.
            if character == "\\", index + 1 < characters.count {
                let next = characters[index + 1]
                if next == "'" || next == "\"" || next == "\\" || (quote == nil && next == " ") {
                    current.append(next); started = true; index += 2; continue
                }
            }
            if quote == nil && (character == "\"" || character == "'") {
                quote = character; started = true; index += 1; continue
            }
            if let quoting = quote, character == quoting { quote = nil; index += 1; continue }
            if character == "#" && quote == nil && !started { break }
            if (character == " " || character == "\t") && quote == nil {
                if started { tokens.append(current); current = ""; started = false }
            } else { current.append(character); started = true }
            index += 1
        }
        guard quote == nil else { throw malformed("Незавершённая кавычка.") }
        if started { tokens.append(current) }
        return Directive(name: name, arguments: tokens, file: file, line: number)
    }
}
