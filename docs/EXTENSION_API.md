# Extension API 1

FarCore extensions run as separate explicitly selected executables. There is no directory scanning, automatic startup, or execution when reading configuration. The host contains no AppKit types. API 1 supports command output, informational panel rows, viewer text and a proposed editor replacement. This is a native contract, not Windows DLL or FAR plugin compatibility.

## Invocation

Create `ExtensionDescriptor(id:title:apiVersion:kind:executableURL:arguments:)` in trusted host code. Call `ExtensionHost(timeout:maximumBytes:).invoke(_:request:cancellation:)` on a background queue with an immutable `ExtensionRequest(kind:text:entries:)`. `ExtensionEntry` contains name, directory flag and byte size; the host sends no filesystem access handles. `ExtensionCancellation.cancel()` can be called when closing the UI. Use one cancellation object per invocation.

Successful calls return `ExtensionInvocation.response` and lifecycle `[starting, running, finished]`. Each invocation starts a fresh process, supplies one JSON request on stdin, collects one JSON response on stdout, waits for exit, then releases pipes and temporary input. No persistent plugin state or in-process callbacks exist. Errors throw `ExtensionAPIError` (launch and filesystem errors may also propagate); the host leaves application documents and operations untouched. The UI must retain the original document snapshot, show a preview, check it has not changed while processing, and require an explicit apply action before using editor replacement text. Returned panel rows are informational and must never become implicit filesystem paths or commands.

Default execution limits are 3 seconds and 1 MiB combined stdout/stderr and input. The byte limit may be configured up to 8 MiB. Output pipes are drained without blocking; exceeding the limit, cancellation, timeout, a signal, nonzero exit, malformed JSON, incompatible version, wrong kind, or invalid output shape fails the invocation. The direct process is killed on cancellation or failure. Stderr is drained but is not interpreted. Descendant processes are not managed; the contract requires extensions to finish their own children. Lifecycle is a completion receipt, not a live event stream.

A subprocess isolates a plugin crash from the app; it is **not an OS security sandbox**. Executables still have the user's OS permissions and can access files or launch children independently of this API. Run only trusted, explicitly selected extensions. The environment is restricted to PATH, LANG and Python bytecode settings; a private temporary working directory is removed after invocation. This API supplies no write operations.

## Wire format

UTF-8 JSON, exact version 1, one object per process. Request:

```json
{"apiVersion":1,"kind":"editor","text":"Hello","entries":[]}
```

`kind` is `command`, `panel`, `viewer`, or `editor`. `text` is optional. Entries have `name`, `isDirectory` and `size` fields. Response:

```json
{"apiVersion":1,"kind":"editor","title":"Uppercase","text":"HELLO","rows":[]}
```

All response fields except `text` are required. Title must have 1–256 characters. Command/viewer/editor responses require text and empty rows. Panel responses require absent/null text and up to 10,000 rows, each `{"label":"Files","value":"12"}`. JSON nesting is limited to 16 levels. Additional JSON fields are ignored for forward-compatible metadata; they cannot cause actions. Descriptor, request and response versions must all equal 1. Incompatible descriptors are rejected before execution.

## Bundled examples

`Examples/Extensions/text-tools.py` is an executable Python 3 script (Python 3 must be installed, such as by Xcode Command Line Tools). Pass exactly one mode argument:

| Mode | Kind | Input | Result |
| --- | --- | --- | --- |
| `checksum` | command | text | SHA-256 of the UTF-8 text snapshot |
| `stats` | panel | entries | File/directory counts and total file bytes |
| `json` | viewer | text | Pretty-printed JSON; invalid JSON fails safely |
| `uppercase` | editor | text | Uppercase replacement proposal |

Checksum intentionally hashes the supplied decoded text, not original file bytes or an arbitrary path. Stats uses the host's supplied entries, without enumerating disk. All examples read stdin and emit API 1 JSON only. They demonstrate the contract without third-party FAR source or dependencies.

## Bounded FAR behavior ports

Two specific FAR editor behaviors are ported through the editor API, rather than claiming complete plugin compatibility:

- `editcase-upper` and `editcase-lower`: EditCase case conversion restricted to ASCII A–Z/a–z. Non-ASCII characters, punctuation and original line endings remain unchanged. No locale-dependent or full Unicode case conversion is claimed.
- `align`: Align `JustifyString` subset for printable ASCII lines shorter than 75 characters, at least two words, exactly one space between words, no leading/trailing spaces or tabs. The line expands to width 75: added spaces divide equally among gaps, with the remainder assigned from the left. Ineligible lines are preserved. Original LF/CRLF/CR endings remain unchanged.

These modes return editor proposals and use the same preview/apply path as other editor extensions. They do not implement the original plugins' menus, block selections, locale rules, full formatting operations or binary interface. The generic `uppercase` demo remains a separate Python Unicode transform and is not the EditCase port.

## FarForMac menu and custom descriptors

The «Расширения» menu runs the bundled examples explicitly. Editor transformations present the complete returned text for review. Apply checks that the original editor is still open, editable, and has the same buffer revision, then registers a normal Undo change; it does not save the document. Panel results open a separate read-only information window. Viewer input is the currently loaded display block, including the hex representation when selected, not the entire source file. UI text input is limited to 512 KiB; JSON-escaped data must also fit the host's byte limit.

«Запустить расширение по описанию…» reads a user-selected regular JSON file up to 64 KiB. This manifest is not executed on import or startup. The UI requires API version 1 and an absolute executable path, then shows the executable, arguments and data scope before explicit launch. Example (replace the path with your own trusted executable):

```json
{
  "id": "my.text-command",
  "title": "My text command",
  "apiVersion": 1,
  "kind": "command",
  "executable": "/absolute/path/to/my-extension",
  "arguments": []
}
```

No shell command is synthesized. As with any locally launched program, a custom executable has the user's OS permissions. Crash/time limits are not a filesystem or network permission boundary. Bundled examples use Python 3 from the development environment; shipping a runtime for a clean Mac remains release work.
