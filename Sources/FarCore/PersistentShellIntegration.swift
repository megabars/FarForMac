import Foundation

/// Opt-in, app-managed zsh. Startup files and history belong to this temporary
/// session; no user rc files are edited. Hooks report state, never run UI actions.
public final class PersistentShellIntegration {
    public struct State: Equatable, Sendable {
        public let ready: Bool
        public let directory: URL?
        public let exitCode: Int?
        public let clearedDraft: Bool
    }
    public let directory: URL
    /// An ordered ZLE widget, rather than a terminal-driver signal which can
    /// flush or overtake queued characters. Used only while editing our prompt.
    public static let clearDraftInput = Data("\u{1b}[777~".utf8)
    let token = UUID().uuidString
    private var frame = Data()
    private var collecting = false
    private var escape = false
    private var overflow = false

    public init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("farmac-shell-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let rc = """
            unset HISTFILE
            SAVEHIST=0
            HISTSIZE=500
            PROMPT='%~ %# '
            RPROMPT=''
            function _farformac_precmd() {
              local farmac_result=$?
              local farmac_directory
              farmac_directory=$(builtin printf '%s' "$PWD" | /usr/bin/base64 | /usr/bin/tr -d '\\r\\n')
              builtin printf -v _farformac_prompt_state '\\033]777;farformac;\(token);ready;%s;%s\\007' "$farmac_result" "$farmac_directory"
            }
            function _farformac_line_init() {
              [[ "$CONTEXT" == start && -z "$BUFFER" ]] && builtin printf '%s' "$_farformac_prompt_state"
            }
            zle -N zle-line-init _farformac_line_init
            function _farformac_clear_draft() {
              BUFFER=''
              CURSOR=0
              zle redisplay
              builtin printf '%s' "${_farformac_prompt_state/;ready;/;cleared;}"
            }
            zle -N _farformac_clear_draft
            bindkey -e
            bindkey '\\e[777~' _farformac_clear_draft
            function _farformac_preexec() {
              builtin printf '\\033]777;farformac;\(token);busy\\007'
            }
            precmd_functions=(_farformac_precmd)
            preexec_functions=(_farformac_preexec)
            unset ZDOTDIR
            """
            let url = directory.appendingPathComponent(".zshrc")
            try Data(rc.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { cleanup(); throw error }
    }
    public func configuration(directory: URL, columns: Int, rows: Int) -> TerminalSession.Configuration {
        .init(directory: directory, shell: "/bin/zsh", columns: columns, rows: rows,
              shellArguments: ["-d", "-i"], environmentOverrides: ["ZDOTDIR": self.directory.path, "TERM": "xterm-256color", "COLORTERM": "truecolor"])
    }
    /// One quoted eval is one shell command, even for multiline user-menu entries.
    /// Encoding prevents terminal controls or embedded newlines from becoming key events.
    public static func submission(_ command: String) throws -> String {
        guard !command.utf8.contains(0), command.utf8.count <= 65_536 else { throw ShellCommandError.invalidSyntax }
        // Ordinary command-bar input remains readable in the terminal transcript.
        if !command.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return command + "\n"
        }
        let encoded = Data(command.utf8).base64EncodedString()
        return "builtin eval -- \"$(/usr/bin/printf '%s' '\(encoded)' | /usr/bin/base64 -D)\"\n"
    }
    public func consume(_ data: Data) -> [State] {
        var states: [State] = []
        for byte in data {
            if collecting {
                if byte == 7 || (escape && byte == 92) {
                    if !overflow, let state = decode(frame) { states.append(state) }
                    collecting = false; escape = false; overflow = false; frame.removeAll(keepingCapacity: true)
                } else if byte == 27 { escape = true }
                else {
                    if escape { overflow = true; escape = false }
                    if frame.count < 16_384 { frame.append(byte) } else { overflow = true }
                }
            } else if escape {
                collecting = byte == 93; escape = byte == 27
                frame.removeAll(keepingCapacity: true); overflow = false
            } else if byte == 27 { escape = true }
        }
        return states
    }
    private func decode(_ data: Data) -> State? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[0] == "777", parts[1] == "farformac", parts[2] == token else { return nil }
        if parts.count == 4, parts[3] == "busy" { return .init(ready: false, directory: nil, exitCode: nil, clearedDraft: false) }
        guard parts.count == 6, parts[3] == "ready" || parts[3] == "cleared", let status = Int(parts[4]), (0...255).contains(status),
              let bytes = Data(base64Encoded: String(parts[5])), bytes.count <= 8192,
              let path = String(data: bytes, encoding: .utf8), path.hasPrefix("/"), !path.contains("\0") else { return nil }
        return .init(ready: true, directory: URL(fileURLWithPath: path), exitCode: status, clearedDraft: parts[3] == "cleared")
    }
    public func cleanup() { try? FileManager.default.removeItem(at: directory) }
    deinit { cleanup() }
}
