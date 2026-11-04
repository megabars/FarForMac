import AppKit
import FarCore

/// A result click must establish keyboard focus as well as row selection.
/// AppKit can otherwise leave Return and arrows with the window responder.
private final class SearchResultsTable: NSTableView {
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

/// A search owns its worker and event stream; it never navigates a file panel
/// until the user explicitly invokes the reveal callback.
@MainActor
final class SearchWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let helpText = """
    РЕКУРСИВНЫЙ ПОИСК — Alt+F7

    В общем поиске отметьте источники: локальные папки или файлы, архивы и сетевые папки. Можно добавить папку, архив или текущие источники файловых панелей, изменить путь и убрать источник. Источники панелей фиксируются в момент добавления; дальнейшая навигация панелей не меняет поиск. Маска имени поддерживает те же выражения и группы, что файловые панели. Режим содержимого: без проверки, буквальная подстрока, регулярное выражение или HEX (байты). HEX: пары 00…FF через пробел, например 00 FF 41; регистр букв HEX не важен. Слитные пары тоже допустимы: 00FF4142. Нечётные цифры, 0x и шаблоны отклоняются до запуска. HEX ищет сырые байты независимо от кодировки и показывает смещение от начала файла (с нуля), без номера строки. Кодировка выбирается явно: UTF-8, UTF-16 LE/BE, Windows-1251/1252, Latin-1 или автоматическое определение; недоступные, двоичные, слишком большие и неподдерживаемые объекты отмечаются в замечаниях.

    Даты вводятся как ГГГГ-ММ-ДД, по местному времени: «с» включает начало дня, «по» — весь указанный день. Пустые поля даты и размера снимают соответствующее ограничение. Размер задаётся в байтах. Ограничение чтения одного файла — от 1 до 4096 МиБ для подстроки и HEX и до 64 МиБ для Regex; подстрока ищется по частям с ограниченной памятью; результатов — от 1 до 10000. Поиск прекращается при достижении лимита результатов.

    Скрытые объекты и переход по символическим ссылкам включаются отдельно. Типы определяют, какие объекты могут стать результатами; папки обходятся также при поиске только файлов. Циклы ссылок и специальные файлы не должны задерживать поиск.

    Cmd+Enter запускает поиск из любого поля. Результаты появляются по мере поиска. «Отменить» сохраняет уже найденные строки. Счётчики учитывают все замечания, внизу показаны первые 200. Параметры сохраняются без списка источников, подключений и паролей; поиск после открытия окна не запускается автоматически.

    Выберите результат: Enter или двойной щелчок — перейти к нему в файловой панели; F3 — просмотр, F4 — редактирование без смены каталогов панелей. Кнопка «Во временную панель» передаёт все найденные на этот момент результаты. Временная панель является снимком. Удалённые или заменённые объекты проверяются повторно перед действием.

    В открытой архивной или сетевой панели Alt+F7 ищет от текущей папки этого источника. Переходы по ссылкам отключены; содержимое проверяется через ограниченные приватные копии, до 64 МиБ на файл. Для сети действует общий предел скачивания 256 МиБ. Enter возвращает к найденному объекту, F3/F4 открывают рабочую копию; изменения отправляются отдельно. Общие результаты можно передать во временную виртуальную панель; каждый объект сохраняет свой исходный источник. При локальном поиске «Искать в архивах» добавляет содержимое архивов; «Включая вложенные архивы» разрешает их рекурсивное раскрытие. В открытой архивной панели доступен поиск во вложенных архивах. Сетевой поиск архивы не раскрывает. Путь архивного результата показывает цепочку «архив !/вложенный архив !/файл». Вложенные архивы доступны только для просмотра; F4 для них отключена. Смешанные результаты сохраняют исходные локальные, архивные и сетевые адреса; рабочие копии не становятся адресами результатов. Для архивного обхода: до 256 контейнеров, 100000 обработанных заголовков, четыре уровня вложения и 256 МиБ суммарной обработки данных (включая повторное чтение при проверках). На содержимое одного файла — до 64 МиБ. При достижении предела поиск завершается частично с сообщением. Для явно отмеченного зашифрованного архива пароль запрашивается перед поиском содержимого или вложенных архивов и хранится только на время этого запуска. Автоматический обход не запрашивает пароли для зашифрованного содержимого.
    """

    private enum WindowEvent {
        case local(SearchResult), provider(ProviderSearchResult), match(SearchMatch), issue(SearchIssue), progress(SearchProgress)
    }
    private enum ResultRow {
        case local(SearchResult), provider(ProviderSearchResult), match(SearchMatch)
    }
    private struct SourceRow { var location: SearchLocation; var checked = true }
    private var sourceRows: [SourceRow] = []
    private var usesMultipleSources = false
    private var availableSources: (() -> [SearchLocation])?
    private var onMatchReveal: ((SearchMatch) -> Void)?
    private var onMatchOpen: ((SearchMatch, Bool) -> Void)?
    private var onMatchesToPanel: (([SearchMatch]) -> Void)?
    private let sourceTable = NSTableView()
    private var rootsScroll: NSScrollView!
    private var sourcesScroll: NSScrollView!
    private var sourceOpeningCancellation: TransferCancellation?
    private lazy var archiveSourceButton = button("Добавить архив…", #selector(addArchiveSources))
    private lazy var panelSourcesButton = button("Источники панелей", #selector(addPanelSources))
    private lazy var editSourceButton = button("Изменить…", #selector(editSource))
    private lazy var removeSourceButton = button("Убрать", #selector(removeSource))
    func retainsRemoteProvider(_ provider: any RemoteProvider) -> Bool {
        if case .remote(let captured, _)? = providerSource, captured === provider { return true }
        return sourceRows.contains { row in
            if case .remote(let captured, _) = row.location { return captured === provider }; return false
        }
    }
    private var selectedSources: [SearchLocation] { sourceRows.filter(\.checked).map(\.location) }
    private var resultRows: [ResultRow] = []
    private var dropResultsAfterCleanup = false
    private var providerSource: ProviderSearchSource?
    private var providerResults: [ProviderSearchResult] = []
    private var providerCancellation: ProviderSearchCancellation?
    private var onProviderReveal: ((ProviderSearchResult) -> Void)?
    private var onProviderOpen: ((ProviderSearchResult, Bool) -> Void)?
    private var parameterKey: String { usesMultipleSources ? "search.multisource.parameters.v1" : providerSource == nil ? Self.parametersKey : "search.provider.parameters.v1" }
    private static let parametersKey = "search.parameters.v1"
    static func runSearchOptionsUISmokeChecks() throws -> [String] {
        guard AppRuntime.isSmoke, let root = AppRuntime.smokeStateDirectory else { throw PanelSessionError("Search smoke requires isolated state") }
        let controller = SearchWindow(directory: root, maskGroups: [:], onReveal: { _ in }, onOpen: { _, _ in }, onSendToPanel: { _ in })
        var options = SearchOptions(roots: [root]); options.contentMode = .literal
        options.contentQuery = "Привет"; options.contentEncoding = .utf16BE; options.maximumContentBytes = 96 * 1_048_576
        controller.restore(options)
        let restored = try controller.readOptions()
        guard restored.contentEncoding == .utf16BE, restored.maximumContentBytes == options.maximumContentBytes,
              controller.contentEncoding.isEnabled else { throw PanelSessionError("Search encoding/streaming limit did not round trip in UI") }
        options.contentEncoding = nil; options.contentMode = .none; options.maximumContentBytes = 8 * 1_048_576
        controller.restore(options)
        guard controller.contentEncoding.indexOfSelectedItem == 1, !controller.contentEncoding.isEnabled else { throw PanelSessionError("Old search options must use UTF-8 and disable encoding without content") }
        return ["Search UI preserves encoding and large literal limit", "Old search options retain UTF-8 without implicit content search"]
    }
    static func runProviderSearchUISmokeChecks() async throws -> [String] {
        guard AppRuntime.isSmoke, let root = AppRuntime.smokeStateDirectory else { throw PanelSessionError("Provider search smoke requires isolated state") }
        let folder = root.appendingPathComponent("provider-search-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sourceFile = folder.appendingPathComponent("alpha.txt")
        try Data("first\nneedle α\n".utf8).write(to: sourceFile)
        let snapshot = try ArchiveWriter.create(sources: [sourceFile], destination: folder.appendingPathComponent("search.zip"), format: .zip)
        var revealed: String?, opened: String?, edited = false
        let archive = SearchWindow(source: .archive(snapshot, prefix: ""), maskGroups: [:],
            onReveal: { revealed = $0.path }, onOpen: { opened = $0.path; edited = $1 })
        defer { archive.close() }
        var options = SearchOptions(roots: [folder]); options.namePattern = "*.txt"; options.contentMode = .literal; options.contentQuery = "needle"
        archive.restore(options); archive.startSearch()
        try await waitForSearch(archive)
        guard archive.providerResults.count == 1, archive.results.isEmpty,
              archive.providerResults.first?.lineNumber == 2, !archive.sendButton.isEnabled,
              !archive.roots.isEditable, !archive.followLinks.isEnabled else { throw PanelSessionError("Archive provider search UI scope/result mismatch") }
        archive.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        archive.revealSelected(); archive.viewSelected()
        guard revealed == "alpha.txt", opened == "alpha.txt", !edited else { throw PanelSessionError("Archive provider result routing mismatch") }
        archive.editSelected()
        guard edited else { throw PanelSessionError("Provider edit callback lost") }
        let provider = ProviderUISmokeFixture()
        let remote = SearchWindow(source: .remote(provider, root: "/docs"), maskGroups: [:], onReveal: { _ in }, onOpen: { _, _ in })
        defer { remote.close() }
        options.contentMode = .none; remote.restore(options); remote.startSearch()
        try await waitForSearch(remote)
        guard remote.providerResults.count == 2, provider.downloads == 0 else { throw PanelSessionError("Metadata search must not download remote contents") }
        options.contentMode = .literal; remote.restore(options); remote.startSearch()
        try await waitForSearch(remote)
        guard remote.providerResults.count == 1, remote.providerResults.first?.path == "/docs/alpha.txt" else { throw PanelSessionError("Remote content results missing") }
        // Closing cancels I/O, but the worker must finish cleanup before exit/unblocking operations.
        provider.waitForCancellation = true; remote.startSearch()
        remote.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: remote.window))
        guard remote.isProviderSearching else { throw PanelSessionError("Closed provider search lost its worker lease") }
        remote.showWindow(nil)
        try await waitForSearch(remote)
        guard !remote.isProviderSearching, remote.startButton.isEnabled, remote.pattern.isEnabled else { throw PanelSessionError("Reopened search must release cleanup lease and re-enable controls") }
        return ["Archive search UI uses provider rows and routes Enter F3 F4",
                "Provider search keeps scope fixed and excludes local temporary path lists",
                "Remote metadata search does not download contents",
                "Remote content search uses bounded copies and returns matching row",
                "Closing and reopening provider search retains cleanup lease and restores controls after cancellation"]
    }
    static func runArchiveTraversalUISmokeChecks() async throws -> [String] {
        guard AppRuntime.isSmoke, let root = AppRuntime.smokeStateDirectory else { throw PanelSessionError("Archive traversal UI smoke requires isolated state") }
        let folder = root.appendingPathComponent("archive-traversal-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = Data([0xFF, 0x00, 0x41, 0x42])
        let member = folder.appendingPathComponent("nested.txt")
        let outerMember = folder.appendingPathComponent("outer.txt")
        let localFile = folder.appendingPathComponent("local.txt")
        for file in [member, outerMember, localFile] { try bytes.write(to: file) }
        let inner = try ArchiveWriter.create(sources: [member], destination: folder.appendingPathComponent("inner.zip"), format: .zip)
        let outer = try ArchiveWriter.create(sources: [inner.sourceURL, outerMember], destination: folder.appendingPathComponent("outer.zip"), format: .zip)
        var localOpenedOffset: Int64?, archiveOpenedOffset: Int64?, revealedPath: String?
        var archiveOpenCount = 0, archiveEditCount = 0, temporaryCount = 0
        let local = SearchWindow(directory: folder, maskGroups: [:], onReveal: { revealedPath = $0.url.path },
            onOpen: { result, _ in localOpenedOffset = result.byteOffset }, onSendToPanel: { temporaryCount += $0.count },
            onArchiveReveal: { revealedPath = SearchDisplayRow($0).path },
            onArchiveOpen: { archiveOpenedOffset = $0.byteOffset; archiveOpenCount += 1; if $1 { archiveEditCount += 1 } })
        defer { local.close() }
        var options = SearchOptions(roots: [localFile, outer.sourceURL])
        options.namePattern = "*.txt"; options.contentMode = .hex; options.contentQuery = "00 41 42"
        options.searchArchives = true; options.searchNestedArchives = true
        local.restore(options)
        let roundTrip = try local.readOptions()
        guard roundTrip.searchArchives == true, roundTrip.searchNestedArchives == true,
              local.searchArchives.isEnabled, local.searchNestedArchives.isEnabled else { throw PanelSessionError("Archive traversal options did not round trip") }
        var old = options; old.searchArchives = nil; old.searchNestedArchives = nil
        local.restore(old)
        guard local.searchArchives.state == .off, local.searchNestedArchives.state == .off,
              !local.searchNestedArchives.isEnabled else { throw PanelSessionError("Old search options enabled archive traversal") }
        local.restore(options); local.startSearch(); try await waitForSearch(local)
        guard local.results.count == 1, local.providerResults.count == 2, local.resultCount == 3,
              !local.sendButton.isEnabled else { throw PanelSessionError("Mixed local and nested archive results missing or temporary panel enabled") }
        local.sendResults()
        guard temporaryCount == 0 else { throw PanelSessionError("Mixed search leaked archive results into a local temporary panel") }
        guard let nestedIndex = local.resultRows.firstIndex(where: {
            if case .provider(let result) = $0 { return result.name == "nested.txt" }; return false
        }) else { throw PanelSessionError("Nested archive result missing behind nonmatching outer name") }
        local.table.selectRowIndexes(IndexSet(integer: nestedIndex), byExtendingSelection: false)
        guard let nested = local.selectedProviderResult, let nestedSnapshot = nested.capturedArchiveSnapshot,
              nestedSnapshot.isReadOnly, nested.byteOffset == 1,
              SearchDisplayRow(nested).path == outer.sourceURL.path + " !/inner.zip !/nested.txt",
              !local.editButton.isEnabled, local.viewButton.isEnabled else { throw PanelSessionError("Nested row path/read-only/HEX state mismatch") }
        let extracted = try ArchiveReader.extract(nestedSnapshot, paths: [nested.path])
        guard try Data(contentsOf: extracted.url(for: nested.path)) == bytes else { extracted.cleanup(); throw PanelSessionError("Nested search result points to wrong snapshot bytes") }
        extracted.cleanup()
        local.revealSelected(); local.viewSelected(); local.editSelected()
        guard revealedPath == outer.sourceURL.path + " !/inner.zip !/nested.txt", archiveOpenedOffset == 1,
              archiveOpenCount == 1, archiveEditCount == 0 else { throw PanelSessionError("Nested Enter/F3/F4 routing mismatch") }
        guard let outerIndex = local.resultRows.firstIndex(where: {
            if case .provider(let result) = $0 { return result.name == "outer.txt" }; return false
        }), let localIndex = local.resultRows.firstIndex(where: {
            if case .local = $0 { return true }; return false
        }) else { throw PanelSessionError("Mixed result row identities missing") }
        local.table.selectRowIndexes(IndexSet(integer: outerIndex), byExtendingSelection: false); local.editSelected()
        guard local.editButton.isEnabled, archiveEditCount == 1 else { throw PanelSessionError("Writable outer archive lost F4") }
        local.table.selectRowIndexes(IndexSet(integer: localIndex), byExtendingSelection: false); local.viewSelected(); local.revealSelected()
        guard localOpenedOffset == 1, revealedPath == localFile.path else { throw PanelSessionError("Local mixed row routed to archive callback") }
        // Force an interleaved batch to verify row order rather than separate source arrays.
        let localResult = local.results[0], archiveResult = local.providerResults[0]
        local.clearResults(); local.isSearching = true
        local.receive([.provider(archiveResult), .local(localResult), .provider(nested)], generation: local.generation)
        local.isSearching = false; local.table.reloadData()
        local.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        guard local.selectedResult?.url == localFile, local.selectedProviderResult == nil else { throw PanelSessionError("Mixed rows changed event order") }
        let opened = SearchWindow(source: .archive(outer, prefix: ""), maskGroups: [:],
                                  onReveal: { _ in }, onOpen: { _, _ in })
        defer { opened.close() }
        opened.restore(options); opened.startSearch(); try await waitForSearch(opened)
        guard opened.providerResults.count == 2, !opened.searchArchives.isEnabled,
              opened.searchNestedArchives.isEnabled else { throw PanelSessionError("Opened archive nested traversal UI mismatch") }
        let remote = SearchWindow(source: .remote(ProviderUISmokeFixture(), root: "/docs"), maskGroups: [:], onReveal: { _ in }, onOpen: { _, _ in })
        defer { remote.close() }
        remote.restore(options)
        let remoteOptions = try remote.readOptions()
        guard !remote.searchArchives.isEnabled, !remote.searchNestedArchives.isEnabled,
              remoteOptions.searchArchives == false, remoteOptions.searchNestedArchives == false else { throw PanelSessionError("Remote UI advertised automatic archive traversal") }
        let retainedCopy = opened.providerResults.first(where: { $0.name == "nested.txt" })?.archiveURL
        opened.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: opened.window))
        guard let retainedCopy, !FileManager.default.fileExists(atPath: retainedCopy.path), opened.resultCount == 0 else {
            throw PanelSessionError("Closing completed archive search retained a private nested copy")
        }
        // Closing invalidates pending deliveries while retaining the worker lease.
        opened.startSearch(); opened.cancel()
        opened.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: opened.window))
        opened.showWindow(nil)
        guard opened.isWorkerRunning, !opened.startButton.isEnabled else { throw PanelSessionError("Close released archive worker before cleanup") }
        try await waitForSearch(opened)
        guard opened.resultCount == 0, opened.startButton.isEnabled else { throw PanelSessionError("Closed archive search delivered stale rows or failed cleanup") }
        local.restore(options); local.startSearch()
        local.searchArchives.state = .off; local.searchNestedArchives.state = .off
        guard local.isProviderSearching else { throw PanelSessionError("Local archive worker lease depends on current toggles") }
        local.cancel(); local.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: local.window))
        guard local.isProviderSearching else { throw PanelSessionError("Closed local archive worker lost mutation/shutdown lease") }
        try await waitForSearch(local)
        guard !local.isProviderSearching, local.resultCount == 0 else { throw PanelSessionError("Local archive worker lease outlived cleanup") }
        return ["Local search UI round trips archive traversal options and leaves old settings off",
                "Mixed results include nested archive matches behind nonmatching container masks and preserve event order",
                "Archive result paths show outer and nested names and open the captured bytes with HEX offsets",
                "Enter and F3 route per result; nested F4 is disabled while outer archive F4 remains available",
                "Mixed archive results cannot enter a local temporary panel",
                "Opened archive supports nested traversal while remote controls stay disabled",
                "Closing and cancelling archive search retains cleanup lease and drops stale rows",
                "Local automatic archive search keeps its mutation/shutdown lease through cancellation and close independently of current toggles"]
    }
    static func runMultiSourceUISmokeChecks() async throws -> [String] {
        guard AppRuntime.isSmoke, let root = AppRuntime.smokeStateDirectory else { throw PanelSessionError("Multi-source UI smoke requires isolated state") }
        let folder = root.appendingPathComponent("multi-source-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = folder.appendingPathComponent("local.txt"), member = folder.appendingPathComponent("archive.txt")
        try Data("needle local".utf8).write(to: local); try Data("needle archive".utf8).write(to: member)
        let snapshot = try ArchiveWriter.create(sources: [member], destination: folder.appendingPathComponent("source.zip"), format: .zip)
        let first = ProviderUISmokeFixture(), second = ProviderUISmokeFixture()
        var revealed: SearchMatch?, opened: SearchMatch?, edited = false, sent: [SearchMatch] = []
        let controller = SearchWindow(sources: [.local(local), .archive(snapshot, prefix: ""), .remote(first, root: "/docs")],
            availableSources: { [.local(local), .remote(second, root: "/docs")] }, maskGroups: [:],
            onReveal: { revealed = $0 }, onOpen: { opened = $0; edited = $1 }, onSendToPanel: { sent = $0 })
        defer { controller.close() }
        guard controller.sourceRows.count == 3, controller.rootsScroll.isHidden, !controller.sourcesScroll.isHidden,
              controller.archiveSourceButton.isHidden == false, !controller.panelSourcesButton.isHidden else {
            throw PanelSessionError("Unified search source controls missing")
        }
        controller.addPanelSources(); controller.addPanelSources()
        guard controller.sourceRows.count == 4 else { throw PanelSessionError("Live panel sources were lost or duplicated") }
        let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        check.tag = 3; check.state = .off; controller.toggleSource(check)
        var options = SearchOptions(roots: [folder]); options.namePattern = "*.txt"
        options.contentMode = .literal; options.contentQuery = "needle"
        options.maximumContentBytes = 96 * 1_048_576
        controller.restore(options); controller.startSearch(); try await waitForSearch(controller)
        guard controller.matches.count == 3 else {
            throw PanelSessionError("Checked multi-source search expected 3 local/archive/remote matches; got \(controller.matches.count). Issues: \(controller.displayedIssues.joined(separator: "; "))")
        }
        guard first.downloads == 2, second.downloads == 0 else {
            throw PanelSessionError("Checked source selection expected two active-provider candidate downloads and none from the unchecked source; got \(first.downloads)/\(second.downloads)")
        }
        guard controller.sendButton.isEnabled else { throw PanelSessionError("Mixed results disabled the virtual temporary-panel action") }
        guard try controller.readOptions().maximumContentBytes == options.maximumContentBytes else {
            throw PanelSessionError("Mixed search changed the large local read limit instead of applying the provider ceiling independently")
        }
        controller.sendResults()
        guard sent.map(\.id) == controller.matches.map(\.id),
              sent.contains(where: { if case .local = $0 { return true }; return false }),
              sent.contains(where: { if case .archive = $0 { return true }; return false }),
              sent.contains(where: { if case .remote(_, let provider) = $0 { return provider === first }; return false }) else {
            throw PanelSessionError("Temporary-panel callback lost typed mixed origins")
        }
        for (index, match) in controller.matches.enumerated() {
            controller.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            controller.revealSelected(); controller.viewSelected()
            guard revealed?.id == match.id, opened?.id == match.id, !edited else { throw PanelSessionError("Mixed Enter/F3 routed to another source") }
            controller.editSelected()
            guard edited, controller.editButton.isEnabled else { throw PanelSessionError("Writable mixed match lost F4") }
            edited = false
        }
        check.state = .on; controller.toggleSource(check)
        controller.startSearch(); try await waitForSearch(controller)
        guard controller.matches.count == 4,
              Set(controller.matches.map(\.id)).count == 4,
              controller.matches.filter({ if case .remote = $0 { return true }; return false }).count == 2 else {
            throw PanelSessionError("Multiple captured providers collided on the same remote path")
        }
        controller.persistParameters()
        guard let saved = AppPreferences.defaults.data(forKey: controller.parameterKey),
              try JSONDecoder().decode(SearchOptions.self, from: saved).roots.isEmpty else {
            throw PanelSessionError("Unified settings serialized runtime sources")
        }
        // Source changes and window close cannot release a running worker lease.
        second.waitForCancellation = true; controller.startSearch()
        let sourceCount = controller.sourceRows.count
        controller.sourceTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        controller.removeSource(); check.state = .off; controller.toggleSource(check)
        guard controller.sourceRows.count == sourceCount, controller.sourceRows[3].checked else { throw PanelSessionError("Running search allowed captured-source mutation") }
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: controller.window))
        guard controller.isProviderSearching, !controller.startButton.isEnabled else { throw PanelSessionError("Unified close dropped cleanup lease") }
        controller.showWindow(nil); try await waitForSearch(controller)
        guard controller.matches.isEmpty, !controller.isProviderSearching, controller.startButton.isEnabled else { throw PanelSessionError("Unified close delivered stale matches or kept its lease") }
        // A user can remove scopes after the worker has finished.
        controller.sourceTable.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        controller.removeSource()
        guard controller.sourceRows.count == 3 else { throw PanelSessionError("Source removal failed after cleanup") }
        return ["Unified search selects, adds, deduplicates and removes captured local/archive/multiple remote scopes",
                "Checked sources share one mixed result list and preserve Enter/F3/F4 source routing",
                "Mixed temporary-panel callback retains every typed original source",
                "Remote identities with equal paths remain distinct and large local limits round trip",
                "Unified settings exclude captured paths, providers and credentials",
                "Unified close cancels the shared worker and retains its lease through cleanup"]
    }

    static func runHexSearchUISmokeChecks() async throws -> [String] {
        guard AppRuntime.isSmoke, let root = AppRuntime.smokeStateDirectory else { throw PanelSessionError("HEX search smoke requires isolated state") }
        let folder = root.appendingPathComponent("hex-search-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("bytes.bin")
        try Data([0xFF, 0xFE, 0, 0x41, 0x42]).write(to: file)
        var openedOffset: Int64?
        let local = SearchWindow(directory: folder, maskGroups: [:], onReveal: { _ in }, onOpen: { result, _ in openedOffset = result.byteOffset }, onSendToPanel: { _ in })
        defer { local.close() }
        var options = SearchOptions(roots: [file]); options.contentMode = .hex
        options.contentQuery = "00 41 42"; options.contentEncoding = .utf16BE
        options.maximumContentBytes = 96 * 1_048_576
        local.restore(options)
        let roundTrip = try local.readOptions()
        guard roundTrip.contentMode == .hex, roundTrip.contentQuery == options.contentQuery,
              roundTrip.maximumContentBytes == options.maximumContentBytes, !local.contentEncoding.isEnabled,
              !local.caseSensitive.isEnabled, !local.directories.isEnabled, local.query.isEnabled else {
            throw PanelSessionError("HEX mode controls/options mismatch")
        }
        local.startSearch(); try await waitForSearch(local)
        guard local.results.count == 1, local.results[0].byteOffset == 2, local.results[0].lineNumber == nil else {
            throw PanelSessionError("Local HEX UI result mismatch")
        }
        local.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); local.viewSelected()
        guard openedOffset == 2 else { throw PanelSessionError("Local HEX F3 lost byte position") }
        openedOffset = nil
        let snapshot = try ArchiveWriter.create(sources: [file], destination: folder.appendingPathComponent("bytes.zip"), format: .zip)
        let archive = SearchWindow(source: .archive(snapshot, prefix: ""), maskGroups: [:], onReveal: { _ in }, onOpen: { result, _ in openedOffset = result.byteOffset })
        defer { archive.close() }
        options.maximumContentBytes = 8 * 1_048_576
        archive.restore(options); archive.startSearch(); try await waitForSearch(archive)
        guard archive.providerResults.first?.byteOffset == 2, archive.providerResults.first?.lineNumber == nil else {
            throw PanelSessionError("Archive HEX UI result mismatch")
        }
        archive.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); archive.viewSelected()
        guard openedOffset == 2 else { throw PanelSessionError("Archive HEX F3 lost byte position") }
        openedOffset = nil
        let provider = ProviderUISmokeFixture()
        let remote = SearchWindow(source: .remote(provider, root: "/docs"), maskGroups: [:], onReveal: { _ in }, onOpen: { result, _ in openedOffset = result.byteOffset })
        defer { remote.close() }
        options.contentQuery = "6E 65 65 64 6C 65"
        remote.restore(options); remote.startSearch(); try await waitForSearch(remote)
        guard remote.providerResults.count == 1, remote.providerResults[0].byteOffset != nil,
              remote.providerResults[0].lineNumber == nil else { throw PanelSessionError("Remote HEX UI result mismatch") }
        remote.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); remote.viewSelected()
        guard openedOffset == remote.providerResults[0].byteOffset else { throw PanelSessionError("Remote HEX F3 lost byte position") }
        options.contentQuery = "0x41"; remote.restore(options)
        var rejected = false
        do { try ProviderSearchEngine.validate(SearchRequest(options: remote.readOptions())) } catch { rejected = true }
        guard rejected, !remote.isWorkerRunning else { throw PanelSessionError("Invalid HEX must be rejected before starting the worker") }
        options.contentMode = .literal; local.restore(options)
        guard local.contentEncoding.isEnabled, local.caseSensitive.isEnabled, local.directories.isEnabled else {
            throw PanelSessionError("Leaving HEX must restore text controls")
        }
        return ["HEX search UI round trips mode and disables encoding, case and directories",
                "HEX UI finds raw bytes in local, archive and remote files with zero-based byte offsets",
                "HEX UI rejects invalid pairs before starting work and restores text controls"]
    }
    private static func waitForSearch(_ controller: SearchWindow) async throws {
        let deadline = Date().addingTimeInterval(8)
        while controller.isWorkerRunning && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        guard !controller.isWorkerRunning else { controller.cancel(); throw PanelSessionError("Provider UI search timed out") }
    }
    private static let issueLimit = 200
    private let maskGroups: [String: String]
    private let onReveal: (SearchResult) -> Void
    private let onOpen: (SearchResult, Bool) -> Void
    private let onSendToPanel: ([SearchResult]) -> Void
    private let roots = NSTextView()
    private let rootHeading = NSTextField(labelWithString: "Корневые папки — по одному пути в строке")
    private let pattern = NSTextField(string: "*")
    private let query = NSTextField(string: "")
    private let contentMode = NSPopUpButton()
    private let contentEncoding = NSPopUpButton()
    private let caseSensitive = NSButton(checkboxWithTitle: "Учитывать регистр", target: nil, action: nil)
    private let hidden = NSButton(checkboxWithTitle: "Скрытые объекты", target: nil, action: nil)
    private let followLinks = NSButton(checkboxWithTitle: "Переходить по ссылкам", target: nil, action: nil)
    private let files = NSButton(checkboxWithTitle: "Файлы", target: nil, action: nil)
    private let directories = NSButton(checkboxWithTitle: "Папки", target: nil, action: nil)
    private let links = NSButton(checkboxWithTitle: "Ссылки", target: nil, action: nil)
    private let searchArchives = NSButton(checkboxWithTitle: "Искать в архивах", target: nil, action: nil)
    private let searchNestedArchives = NSButton(checkboxWithTitle: "Включая вложенные архивы", target: nil, action: nil)
    private let minSize = NSTextField(string: "")
    private let maxSize = NSTextField(string: "")
    private let afterDate = NSTextField(string: "")
    private let beforeDate = NSTextField(string: "")
    private let contentMB = NSTextField(string: "8")
    private let resultLimit = NSTextField(string: "10000")
    private let table = SearchResultsTable()
    private let issues = NSTextView()
    private let status = NSTextField(wrappingLabelWithString: "Задайте параметры и нажмите «Найти».")
    private let currentPath = NSTextField(labelWithString: "")
    private let issueHeading = NSTextField(labelWithString: "Ошибки и замечания: 0")
    private let progress = NSProgressIndicator()
    private lazy var chooseRootButton = button("Добавить папку…", #selector(addRoot))
    private lazy var startButton = button("Найти", #selector(startSearch))
    private lazy var cancelButton = button("Отменить", #selector(cancelSearch))
    private lazy var revealButton = button("Перейти ↵", #selector(revealSelected))
    private lazy var viewButton = button("F3 Просмотр", #selector(viewSelected))
    private lazy var editButton = button("F4 Правка", #selector(editSelected))
    private lazy var sendButton = button("Во временную панель", #selector(sendResults))
    private var results: [SearchResult] = []
    private var displayedIssues: [String] = []
    private var issueCount = 0
    private var cancellation: SearchCancellation?
    private var generation = UUID()
    private var keyMonitor: Any?
    private var parameterControls: [NSControl] = []
    private var retainedWhileOpen: SearchWindow?
    private(set) var isSearching = false
    private(set) var isWorkerRunning = false
    // Captured at launch: toggles and window visibility cannot release a running worker's lease.
    private var workerUsesProvider = false
    var isProviderSearching: Bool { isWorkerRunning && workerUsesProvider }
    var canStart: () -> Bool = { true }
    var selectedResult: SearchResult? {
        guard resultRows.indices.contains(table.selectedRow), case .local(let result) = resultRows[table.selectedRow] else { return nil }
        return result
    }

    init(directory: URL, maskGroups: [String: String], onReveal: @escaping (SearchResult) -> Void,
         onOpen: @escaping (SearchResult, Bool) -> Void, onSendToPanel: @escaping ([SearchResult]) -> Void,
         onArchiveReveal: ((ProviderSearchResult) -> Void)? = nil,
         onArchiveOpen: ((ProviderSearchResult, Bool) -> Void)? = nil) {
        self.maskGroups = maskGroups
        self.onReveal = onReveal
        self.onOpen = onOpen
        self.onSendToPanel = onSendToPanel
        self.onProviderReveal = onArchiveReveal
        self.onProviderOpen = onArchiveOpen
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Поиск файлов — Alt+F7"
        window.minSize = NSSize(width: 940, height: 730)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        configureContent()
        var options = SearchOptions(roots: [directory])
        if let data = AppPreferences.defaults.data(forKey: Self.parametersKey),
           let saved = try? JSONDecoder().decode(SearchOptions.self, from: data) { options = saved }
        restore(options)
        refreshActions()
        window.initialFirstResponder = pattern
    }

    convenience init(source: ProviderSearchSource, maskGroups: [String: String],
                     onReveal: @escaping (ProviderSearchResult) -> Void,
                     onOpen: @escaping (ProviderSearchResult, Bool) -> Void) {
        self.init(directory: URL(fileURLWithPath: "/"), maskGroups: maskGroups,
                  onReveal: { _ in }, onOpen: { _, _ in }, onSendToPanel: { _ in })
        providerSource = source; onProviderReveal = onReveal; onProviderOpen = onOpen
        var options = SearchOptions(roots: [URL(fileURLWithPath: "/")])
        if let data = AppPreferences.defaults.data(forKey: parameterKey),
           let saved = try? JSONDecoder().decode(SearchOptions.self, from: data) { options = saved }
        options.followSymbolicLinks = false
        options.maximumContentBytes = min(options.maximumContentBytes, 64 * 1_048_576)
        restore(options); roots.string = source.caption
        rootHeading.stringValue = "Источник поиска — текущая папка провайдера и вложенные папки"
        window?.title = "Поиск — " + source.caption
        sendButton.toolTip = "Результаты провайдера открываются через Enter, F3 и F4; локальные списки путей их не поддерживают."
        refreshActions()
    }

    /// Captured sources stay valid while panels navigate independently. Only selected
    /// entries participate; live panel sources are captured when the button is clicked.
    convenience init(sources: [SearchLocation], availableSources: (() -> [SearchLocation])? = nil,
                     maskGroups: [String: String], onReveal: @escaping (SearchMatch) -> Void,
                     onOpen: @escaping (SearchMatch, Bool) -> Void,
                     onSendToPanel: @escaping ([SearchMatch]) -> Void) {
        self.init(directory: URL(fileURLWithPath: "/"), maskGroups: maskGroups,
                  onReveal: { _ in }, onOpen: { _, _ in }, onSendToPanel: { _ in })
        usesMultipleSources = true; self.availableSources = availableSources
        onMatchReveal = onReveal; onMatchOpen = onOpen; onMatchesToPanel = onSendToPanel
        appendSources(sources)
        var options = SearchOptions(roots: [])
        if let data = AppPreferences.defaults.data(forKey: parameterKey),
           let saved = try? JSONDecoder().decode(SearchOptions.self, from: data) { options = saved }
        restore(options)
        rootHeading.stringValue = "Источники поиска — отметьте нужные"
        window?.minSize = NSSize(width: 940, height: 810)
        window?.setContentSize(NSSize(width: 1040, height: 880))
        rootsScroll.isHidden = true; sourcesScroll.isHidden = false
        archiveSourceButton.superview?.isHidden = false
        for control in [archiveSourceButton, editSourceButton, removeSourceButton] { control.isHidden = false }
        panelSourcesButton.isHidden = availableSources == nil
        sendButton.toolTip = "Передать снимок всех найденных объектов с сохранением их источников."
        refreshActions()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        retainedWhileOpen = self
        installKeyMonitor()
        super.showWindow(sender)
    }

    func cancel() {
        guard isSearching else { return }
        cancellation?.cancel(); providerCancellation?.cancel(); sourceOpeningCancellation?.cancel()
        cancelButton.isEnabled = false
        status.stringValue = "Отмена… Уже найденные результаты сохраняются."
    }

    func windowWillClose(_ notification: Notification) {
        persistParameters()
        cancellation?.cancel(); providerCancellation?.cancel(); sourceOpeningCancellation?.cancel()
        generation = UUID() // Any callbacks already waiting for the main thread are stale.
        // Keep cancellation and captured snapshots alive until the worker has cleaned up.
        isSearching = false
        if isWorkerRunning { dropResultsAfterCleanup = true }
        else { clearResults(); table.reloadData(); cancellation = nil; providerCancellation = nil }
        refreshActions()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        retainedWhileOpen = nil
    }

    private func configureContent() {
        startButton.keyEquivalent = "\r"
        startButton.keyEquivalentModifierMask = .command
        contentMode.addItems(withTitles: ["Без проверки", "Подстрока", "Regex", "HEX (байты)"])
        contentMode.target = self; contentMode.action = #selector(modeChanged)
        contentEncoding.addItems(withTitles: ViewerEncoding.allCases.map { L10n.text($0.title) })
        contentEncoding.setAccessibilityLabel(L10n.text("Кодировка содержимого"))
        configureTextView(roots, editable: true)
        roots.setAccessibilityLabel("Корневые папки, по одному абсолютному пути в строке")
        let rootScroll = scroll(roots)
        rootsScroll = rootScroll
        rootScroll.heightAnchor.constraint(equalToConstant: 58).isActive = true
        sourceTable.delegate = self; sourceTable.dataSource = self
        sourceTable.rowHeight = 24; sourceTable.headerView = nil
        sourceTable.setAccessibilityLabel("Источники общего поиска")
        let enabledColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("enabled"))
        enabledColumn.width = 30; enabledColumn.minWidth = 30; enabledColumn.maxWidth = 30
        sourceTable.addTableColumn(enabledColumn)
        let sourceColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        sourceColumn.width = 850; sourceTable.addTableColumn(sourceColumn)
        sourceTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        sourcesScroll = scroll(sourceTable); sourcesScroll.isHidden = true
        sourcesScroll.heightAnchor.constraint(equalToConstant: 96).isActive = true
        let rootInputs = column([rootScroll, sourcesScroll], spacing: 0)
        rootScroll.widthAnchor.constraint(equalTo: rootInputs.widthAnchor).isActive = true
        sourcesScroll.widthAnchor.constraint(equalTo: rootInputs.widthAnchor).isActive = true
        pattern.placeholderString = "Например: *.swift;*.txt|build*"
        pattern.setAccessibilityLabel("Маска имени")
        query.placeholderString = "Искомый текст или регулярное выражение"
        query.setAccessibilityLabel("Содержимое")
        for (field, placeholder, title) in [(minSize, "нет", "Минимальный размер в байтах"), (maxSize, "нет", "Максимальный размер в байтах"),
                                          (afterDate, "ГГГГ-ММ-ДД", "Изменён начиная с даты"), (beforeDate, "ГГГГ-ММ-ДД", "Изменён по дату включительно"),
                                          (contentMB, "1…64", "Лимит чтения файла в МиБ"), (resultLimit, "1…10000", "Лимит результатов")] {
            field.placeholderString = placeholder
            field.setAccessibilityLabel(title)
            field.widthAnchor.constraint(equalToConstant: field === afterDate || field === beforeDate ? 118 : 95).isActive = true
        }
        let choose = chooseRootButton
        parameterControls = [pattern, query, contentMode, contentEncoding, caseSensitive, hidden, followLinks,
                             files, directories, links, searchArchives, searchNestedArchives, minSize, maxSize, afterDate, beforeDate,
                             contentMB, resultLimit, choose, archiveSourceButton, panelSourcesButton, editSourceButton, removeSourceButton]
        rootHeading.font = .systemFont(ofSize: 12, weight: .semibold)
        let rootTitle = row([rootHeading, NSView(), choose])
        let sourceActions = row([archiveSourceButton, panelSourcesButton, editSourceButton, removeSourceButton, NSView()])
        for control in [archiveSourceButton, panelSourcesButton, editSourceButton, removeSourceButton] { control.isHidden = true }
        // A hidden action row collapses in legacy single-source windows.
        sourceActions.isHidden = true
        sourceActions.identifier = NSUserInterfaceItemIdentifier("sourceActions")
        let nameRow = row([text("Маска имени:"), pattern])
        let contentRow = row([text("Содержимое:"), contentMode, contentEncoding, query])
        query.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let flags = row([caseSensitive, hidden, followLinks, NSView()])
        let types = row([text("Типы:"), files, directories, links, NSView()])
        searchArchives.target = self; searchArchives.action = #selector(archiveModeChanged)
        searchArchives.toolTip = "Искать также среди элементов локальных архивов независимо от маски имени самого архива."
        searchNestedArchives.toolTip = "Открывать вложенные архивы в пределах лимитов глубины и рабочих копий; результаты только для чтения."
        let archiveFlags = row([searchArchives, searchNestedArchives, NSView()])
        let sizes = row([text("Размер, байт: от"), minSize, text("до"), maxSize, NSView(), text("Читать файл до, МиБ:"), contentMB])
        let dates = row([text("Изменён с:"), afterDate, text("по:"), beforeDate, text("включительно; пусто — без границы", size: 11), NSView()])
        let limits = row([text("Максимум результатов:"), resultLimit, NSView(), startButton, cancelButton])
        let form = column([rootTitle, rootInputs, sourceActions, nameRow, contentRow, flags, types, archiveFlags, sizes, dates, limits], spacing: 7)
        for view in [rootTitle, rootInputs, sourceActions, nameRow, contentRow, flags, types, archiveFlags, sizes, dates, limits] {
            view.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        }
        table.delegate = self; table.dataSource = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = 24
        table.target = self; table.doubleAction = #selector(revealSelected)
        table.setAccessibilityLabel("Результаты рекурсивного поиска")
        for (identifier, title, width) in [("name", "Имя", 190.0), ("parent", "Родительская папка", 280.0), ("size", "Байт", 80.0),
                                           ("modified", "Изменён", 140.0), ("snippet", "Совпадение", 270.0)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            col.title = title; col.width = width; col.minWidth = 60
            table.addTableColumn(col)
        }
        let resultsScroll = scroll(table)
        resultsScroll.hasHorizontalScroller = true
        resultsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        configureTextView(issues, editable: false)
        issues.setAccessibilityLabel("Ошибки и замечания поиска")
        let issuesScroll = scroll(issues)
        issuesScroll.heightAnchor.constraint(equalToConstant: 85).isActive = true
        issueHeading.font = .systemFont(ofSize: 11, weight: .medium)
        status.font = .systemFont(ofSize: 12)
        status.isSelectable = true
        status.setAccessibilityLabel("Состояние поиска")
        currentPath.font = .systemFont(ofSize: 10)
        currentPath.textColor = .secondaryLabelColor
        currentPath.lineBreakMode = .byTruncatingMiddle
        currentPath.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progress.style = .spinning; progress.controlSize = .small; progress.isIndeterminate = true
        progress.isDisplayedWhenStopped = false
        let statusRow = row([progress, status])
        let actions = row([revealButton, viewButton, editButton, NSView(), sendButton])
        let content = NSView()
        let stack = column([form, statusRow, currentPath, resultsScroll, actions, issueHeading, issuesScroll], spacing: 8)
        content.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
        for view in [form, statusRow, currentPath, resultsScroll, actions, issueHeading, issuesScroll] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        window?.contentView = content
    }

    private func restore(_ options: SearchOptions) {
        roots.string = options.roots.map(\.path).joined(separator: "\n")
        pattern.stringValue = options.namePattern
        query.stringValue = options.contentQuery
        switch options.contentMode { case .none: contentMode.selectItem(at: 0); case .literal: contentMode.selectItem(at: 1); case .regex: contentMode.selectItem(at: 2); case .hex: contentMode.selectItem(at: 3) }
        contentEncoding.selectItem(at: ViewerEncoding.allCases.firstIndex(of: options.contentEncoding ?? .utf8) ?? 1)
        caseSensitive.state = options.caseSensitive ? .on : .off
        hidden.state = options.includeHidden ? .on : .off
        followLinks.state = options.followSymbolicLinks ? .on : .off
        searchArchives.state = options.searchArchives == true ? .on : .off
        searchNestedArchives.state = options.searchNestedArchives == true ? .on : .off
        files.state = options.kinds.contains(.file) ? .on : .off
        directories.state = options.kinds.contains(.directory) ? .on : .off
        links.state = options.kinds.contains(.symbolicLink) ? .on : .off
        minSize.stringValue = options.minSize.map(String.init) ?? ""
        maxSize.stringValue = options.maxSize.map(String.init) ?? ""
        let formatter = dateFormatter()
        afterDate.stringValue = options.modifiedAfter.map { formatter.string(from: $0) } ?? ""
        beforeDate.stringValue = options.modifiedBefore.map { formatter.string(from: $0) } ?? ""
        contentMB.stringValue = String(max(1, min(4096, options.maximumContentBytes / (1024 * 1024))))
        resultLimit.stringValue = String(max(1, min(10000, options.maximumResults)))
        modeChanged(); archiveModeChanged()
    }

    private struct InputError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private func readOptions() throws -> SearchOptions {
        let rootText = usesMultipleSources ? "/" : providerSource == nil ? roots.string : "/"
        if usesMultipleSources && selectedSources.isEmpty { throw InputError(message: "Отметьте хотя бы один источник поиска.") }
        let paths = rootText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !paths.isEmpty else { throw InputError(message: "Укажите хотя бы одну корневую папку.") }
        let expanded = paths.map { ($0 as NSString).expandingTildeInPath }
        guard expanded.allSatisfy({ ($0 as NSString).isAbsolutePath && !$0.contains("\0") }) else {
            throw InputError(message: "Для каждой корневой папки нужен абсолютный путь, по одному в строке.")
        }
        var options = SearchOptions(roots: expanded.map { URL(fileURLWithPath: $0).standardizedFileURL })
        options.namePattern = pattern.stringValue
        options.contentQuery = query.stringValue
        options.contentMode = contentMode.indexOfSelectedItem == 1 ? .literal : contentMode.indexOfSelectedItem == 2 ? .regex : contentMode.indexOfSelectedItem == 3 ? .hex : .none
        options.contentEncoding = ViewerEncoding.allCases[max(0, contentEncoding.indexOfSelectedItem)]
        options.caseSensitive = caseSensitive.state == .on
        options.includeHidden = hidden.state == .on
        options.followSymbolicLinks = (usesMultipleSources || providerSource == nil) && followLinks.state == .on
        options.searchArchives = (usesMultipleSources ? selectedSources.contains(where: \.isLocalSearchSource) : providerSource == nil) && searchArchives.state == .on
        options.searchNestedArchives = (usesMultipleSources ? selectedSources.contains { $0.isLocalSearchSource || $0.isArchiveSearchSource } : providerSource?.supportsArchiveTraversal != false) && searchNestedArchives.state == .on
        var kinds = Set<SearchFileKind>()
        if files.state == .on { kinds.insert(.file) }
        if directories.state == .on { kinds.insert(.directory) }
        if links.state == .on { kinds.insert(.symbolicLink) }
        guard !kinds.isEmpty else { throw InputError(message: "Выберите хотя бы один тип объектов.") }
        options.kinds = kinds
        options.minSize = try optionalSize(minSize, title: "Минимальный размер")
        options.maxSize = try optionalSize(maxSize, title: "Максимальный размер")
        if let low = options.minSize, let high = options.maxSize, low > high { throw InputError(message: "Минимальный размер больше максимального.") }
        options.modifiedAfter = try optionalDate(afterDate, upperBound: false)
        options.modifiedBefore = try optionalDate(beforeDate, upperBound: true)
        if let low = options.modifiedAfter, let high = options.modifiedBefore, low > high { throw InputError(message: "Начальная дата позже конечной.") }
        let maximum = (usesMultipleSources || providerSource == nil) && (options.contentMode == .literal || options.contentMode == .hex) ? 4096 : 64
        guard let mb = Int(contentMB.stringValue.trimmingCharacters(in: .whitespaces)), (1...maximum).contains(mb) else {
            throw InputError(message: providerSource == nil ? "Лимит чтения: до 4096 МиБ для подстроки и HEX, до 64 МиБ для Regex." : "Лимит чтения в архиве или сети: от 1 до 64 МиБ на файл.")
        }
        guard let limit = Int(resultLimit.stringValue.trimmingCharacters(in: .whitespaces)), (1...10000).contains(limit) else {
            throw InputError(message: "Лимит результатов должен быть целым числом от 1 до 10000.")
        }
        options.maximumContentBytes = mb * 1024 * 1024
        options.maximumResults = limit
        return options
    }

    private func optionalSize(_ field: NSTextField, title: String) throws -> Int64? {
        let raw = field.stringValue.trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { return nil }
        guard let value = Int64(raw), value >= 0 else { throw InputError(message: "\(title): введите неотрицательное целое число байт или очистите поле.") }
        return value
    }
    private func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
    private func optionalDate(_ field: NSTextField, upperBound: Bool) throws -> Date? {
        let raw = field.stringValue.trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { return nil }
        let formatter = dateFormatter()
        guard raw.count == 10, let date = formatter.date(from: raw), formatter.string(from: date) == raw else {
            throw InputError(message: "Дата должна иметь вид ГГГГ-ММ-ДД, например 2026-10-28, или быть пустой.")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let start = calendar.startOfDay(for: date)
        if upperBound {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: start) else { throw InputError(message: "Не удалось определить конец дня.") }
            // The closest representable instant before midnight includes the
            // full day without accidentally excluding its final microsecond.
            return Date(timeIntervalSinceReferenceDate: nextDay.timeIntervalSinceReferenceDate.nextDown)
        }
        return start
    }

    private func persistParameters() {
        guard var options = try? readOptions() else { return }
        if usesMultipleSources { options.roots = [] } // Captured providers and paths are never serialized.
        guard let data = try? JSONEncoder().encode(options) else { return }
        AppPreferences.defaults.set(data, forKey: parameterKey)
    }

    @objc private func startSearch() {
        guard !isWorkerRunning else { return }
        guard canStart() else { status.stringValue = "Дождитесь завершения файловых операций перед поиском."; return }
        do {
            let options = try readOptions()
            let request = SearchRequest(options: options, maskGroups: maskGroups)
            if usesMultipleSources { try SearchEngine.validate(request) }
            else if providerSource != nil { try ProviderSearchEngine.validate(request) }
            else { try SearchEngine.validate(request) }
            var password: String?
            if options.contentMode != .none || options.searchNestedArchives == true,
               case .archive(let snapshot, _) = providerSource, snapshot.isEncrypted {
                let alert = NSAlert(); alert.messageText = "Пароль архива для поиска"
                alert.informativeText = snapshot.sourceURL.lastPathComponent
                let field = NSSecureTextField(string: ""); field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
                alert.accessoryView = field; alert.addButton(withTitle: "Найти"); alert.addButton(withTitle: "Отмена")
                alert.window.initialFirstResponder = field
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                password = field.stringValue; field.stringValue = ""
            }
            var archivePasswords: [URL: String] = [:]
            if usesMultipleSources && (options.contentMode != .none || options.searchNestedArchives == true) {
                for location in selectedSources {
                    guard case .archive(let snapshot, _) = location, snapshot.isEncrypted,
                          archivePasswords[snapshot.sourceURL] == nil else { continue }
                    guard let value = requestArchivePassword(snapshot) else { return }
                    archivePasswords[snapshot.sourceURL] = value
                }
            }
            persistParameters()
            let id = UUID()
            generation = id
            let token = SearchCancellation()
            cancellation = token
            let source = providerSource
            let locations = usesMultipleSources ? selectedSources : nil
            let providerToken = ProviderSearchCancellation()
            providerCancellation = source == nil && locations == nil ? nil : providerToken
            clearResults()
            dropResultsAfterCleanup = false
            displayedIssues.removeAll(keepingCapacity: true)
            issueCount = 0; issues.string = ""; currentPath.stringValue = ""
            issueHeading.stringValue = "Ошибки и замечания: 0"
            table.reloadData()
            workerUsesProvider = locations != nil || source != nil || options.searchArchives == true
            isSearching = true; isWorkerRunning = true
            status.stringValue = "Поиск… Просмотрено: 0 · Найдено: 0 · Замечаний: 0"
            progress.startAnimation(nil)
            refreshActions()
            // At most 64 events await delivery. The worker blocks at the batch
            // boundary, so a fast scan cannot flood the main dispatch queue.
            let searchPassword = password
            let searchPasswords = archivePasswords
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                var batch: [WindowEvent] = []
                var lastDelivery = Date.timeIntervalSinceReferenceDate
                func flush() {
                    guard !batch.isEmpty else { return }
                    let events = batch
                    batch.removeAll(keepingCapacity: true)
                    lastDelivery = Date.timeIntervalSinceReferenceDate
                    DispatchQueue.main.sync { self.receive(events, generation: id) }
                }
                func enqueue(_ event: WindowEvent) {
                    batch.append(event)
                    if batch.count >= 64 || Date.timeIntervalSinceReferenceDate - lastDelivery >= 0.08 { flush() }
                }
                let summary: SearchSummary
                if let locations {
                    summary = MultiSourceSearchEngine.run(locations: locations, request: request,
                        archivePasswords: searchPasswords, cancellation: providerToken) { event in
                        switch event {
                        case .match(let value): enqueue(.match(value))
                        case .issue(let value): enqueue(.issue(value))
                        case .progress(let value): enqueue(.progress(value))
                        }
                    }
                } else if let source {
                    summary = source.run(request, password: searchPassword, cancellation: providerToken) { event in
                        switch event {
                        case .result(let value): enqueue(.provider(value))
                        case .issue(let value): enqueue(.issue(value))
                        case .progress(let value): enqueue(.progress(value))
                        }
                    }
                } else {
                    summary = SearchEngine.run(request, cancellation: token) { event in
                        switch event {
                        case .result(let value): enqueue(.local(value))
                        case .archiveResult(let value): enqueue(.provider(value))
                        case .issue(let value): enqueue(.issue(value))
                        case .progress(let value): enqueue(.progress(value))
                        }
                    }
                }
                flush()
                DispatchQueue.main.async { self.finish(summary, generation: id) }
            }
        } catch {
            status.stringValue = error.localizedDescription
            status.textColor = .systemRed
        }
    }

    private func receive(_ events: [WindowEvent], generation id: UUID) {
        guard generation == id, isSearching else { return }
        var addedResults = false
        var addedIssues = false
        var latestProgress: SearchProgress?
        for event in events {
            switch event {
            case .local(let result):
                if resultRows.count < 10000 { results.append(result); resultRows.append(.local(result)); addedResults = true }
            case .provider(let result):
                if resultRows.count < 10000 { providerResults.append(result); resultRows.append(.provider(result)); addedResults = true }
            case .match(let result):
                if resultRows.count < 10000 { resultRows.append(.match(result)); addedResults = true }
            case .issue(let issue):
                issueCount += 1
                if displayedIssues.count < Self.issueLimit {
                    // Keep issue text bounded even when an OS error embeds a long string.
                    displayedIssues.append("\(String(describing: issue.path).prefix(4096)): \(issue.message.prefix(2048))")
                    addedIssues = true
                }
            case .progress(let value): latestProgress = value
            }
        }
        if addedResults {
            let selection = table.selectedRow
            table.reloadData()
            if (0..<resultCount).contains(selection) { table.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false) }
            refreshActions()
        }
        if addedIssues { issues.string = displayedIssues.joined(separator: "\n\n") }
        updateIssueHeading()
        if let latestProgress {
            status.stringValue = "Просмотрено: \(latestProgress.scanned) · Найдено: \(latestProgress.matches) · Замечаний: \(latestProgress.errors)"
            currentPath.stringValue = latestProgress.currentPath
            currentPath.toolTip = latestProgress.currentPath
        }
    }

    private func finish(_ summary: SearchSummary, generation id: UUID) {
        isWorkerRunning = false; workerUsesProvider = false
        if dropResultsAfterCleanup { clearResults(); dropResultsAfterCleanup = false; table.reloadData() }
        guard generation == id, isSearching else {
            // A closed controller can be reopened while its cancelled worker cleans up.
            // Restore its controls after that worker releases the lease.
            if !isSearching {
                cancellation = nil; providerCancellation = nil
                progress.stopAnimation(nil); status.stringValue = "Поиск остановлен. Можно запустить новый поиск."
                refreshActions()
            }
            return
        }
        isSearching = false; cancellation = nil; providerCancellation = nil
        progress.stopAnimation(nil)
        issueCount = max(issueCount, summary.errors)
        updateIssueHeading()
        status.stringValue = summary.summary
        currentPath.stringValue = ""
        refreshActions()
    }
    private func updateIssueHeading() {
        issueHeading.stringValue = "Ошибки и замечания: \(issueCount)" + (issueCount > Self.issueLimit ? " · показаны первые \(Self.issueLimit), остальные учтены в счётчике" : "")
    }

    @objc private func cancelSearch() { cancel() }
    @objc private func modeChanged() {
        query.isEnabled = !isWorkerRunning && contentMode.indexOfSelectedItem != 0
        let hex = contentMode.indexOfSelectedItem == 3
        contentEncoding.isEnabled = query.isEnabled && !hex
        caseSensitive.isEnabled = !isWorkerRunning && !hex
        directories.isEnabled = !isWorkerRunning && !hex
        query.placeholderString = hex ? "Пары байтов: 00 FF 41 42" : "Искомый текст или регулярное выражение"
        query.toolTip = hex ? "Пары 00…FF через пробел. Смещение в результате считается с нуля; кодировка и регистр текста не влияют." : nil
        contentMB.placeholderString = (usesMultipleSources || providerSource == nil) && [1, 3].contains(contentMode.indexOfSelectedItem) ? "1…4096" : "1…64"
    }
    @objc private func archiveModeChanged() {
        searchArchives.isEnabled = !isWorkerRunning && (usesMultipleSources ? selectedSources.contains(where: \.isLocalSearchSource) : providerSource == nil)
        searchNestedArchives.isEnabled = !isWorkerRunning && (usesMultipleSources ? selectedSources.contains(where: \.isArchiveSearchSource) || (selectedSources.contains(where: \.isLocalSearchSource) && searchArchives.state == .on) : (providerSource?.supportsArchiveTraversal ?? (searchArchives.state == .on)))
    }
    @objc private func addRoot() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = usesMultipleSources; panel.allowsMultipleSelection = true
        panel.prompt = "Добавить"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            if self.usesMultipleSources { self.appendSources(panel.urls.map { .local($0.standardizedFileURL) }); return }
            var paths = self.roots.string.components(separatedBy: .newlines).filter { !$0.isEmpty }
            for url in panel.urls where !paths.contains(url.path) { paths.append(url.path) }
            self.roots.string = paths.joined(separator: "\n")
        }
    }
    private func requestArchivePassword(_ snapshot: ArchiveSnapshot) -> String? {
        let alert = NSAlert(); alert.messageText = "Пароль архива для поиска"
        alert.informativeText = ArchiveNavigationFrame(snapshot: snapshot).displayPath
        let field = NSSecureTextField(string: ""); field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "Найти"); alert.addButton(withTitle: "Отмена")
        alert.window.initialFirstResponder = field
        defer { field.stringValue = "" }
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
    private func appendSources(_ locations: [SearchLocation]) {
        var identities = Set(sourceRows.map { $0.location.searchSourceID })
        for location in locations where identities.insert(location.searchSourceID).inserted {
            sourceRows.append(SourceRow(location: location))
        }
        sourceTable.reloadData(); refreshActions()
    }
    @objc private func addPanelSources() {
        guard !isWorkerRunning else { return }
        appendSources(availableSources?() ?? [])
    }
    private func sourceCell(_ column: NSTableColumn?, row: Int) -> NSView? {
        guard sourceRows.indices.contains(row) else { return nil }
        if column?.identifier.rawValue == "enabled" {
            let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleSource(_:)))
            check.tag = row; check.state = sourceRows[row].checked ? .on : .off; check.isEnabled = !isWorkerRunning
            check.setAccessibilityLabel("Искать: " + sourceRows[row].location.searchCaption)
            return check
        }
        let field = NSTextField(labelWithString: sourceRows[row].location.searchCaption)
        field.font = .systemFont(ofSize: 11); field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = field.stringValue
        return field
    }
    @objc private func toggleSource(_ sender: NSButton) {
        guard !isWorkerRunning, sourceRows.indices.contains(sender.tag) else { return }
        sourceRows[sender.tag].checked = sender.state == .on; refreshActions()
    }
    @objc private func removeSource() {
        guard !isWorkerRunning, sourceRows.indices.contains(sourceTable.selectedRow) else { return }
        sourceRows.remove(at: sourceTable.selectedRow); sourceTable.reloadData(); refreshActions()
    }
    @objc private func editSource() {
        let index = sourceTable.selectedRow
        guard !isWorkerRunning, sourceRows.indices.contains(index) else { return }
        let source = sourceRows[index].location
        let alert = NSAlert(); alert.messageText = "Путь источника поиска"
        let path: String
        switch source {
        case .local(let url): path = url.path; alert.informativeText = "Абсолютный путь папки или файла."
        case .archive(_, let prefix): path = prefix; alert.informativeText = "Папка внутри выбранного архива; пусто — весь архив."
        case .remote(_, let root): path = root; alert.informativeText = "Абсолютный путь на выбранном подключении."
        }
        let field = NSTextField(string: path); field.frame = NSRect(x: 0, y: 0, width: 500, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "Сохранить"); alert.addButton(withTitle: "Отмена")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement: SearchLocation
            switch source {
            case .local:
                let expanded = (value as NSString).expandingTildeInPath
                guard (expanded as NSString).isAbsolutePath, !expanded.contains("\0") else { throw InputError(message: "Введите абсолютный путь.") }
                replacement = .local(URL(fileURLWithPath: expanded).standardizedFileURL)
            case .archive(let snapshot, _):
                let clean = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !clean.contains("\0"), !clean.split(separator: "/").contains(".."),
                      clean.isEmpty || snapshot.entries.contains(where: { $0.path == clean && $0.isDirectory || $0.path.hasPrefix(clean + "/") }) else {
                    throw InputError(message: "Укажите существующую папку архива.")
                }
                replacement = .archive(snapshot, prefix: clean)
            case .remote(let provider, _): replacement = .remote(provider, root: try RemotePath.validate(value))
            }
            guard !sourceRows.enumerated().contains(where: { $0.offset != index && $0.element.location.searchSourceID == replacement.searchSourceID }) else {
                throw InputError(message: "Такой источник уже добавлен.")
            }
            sourceRows[index].location = replacement; sourceTable.reloadData(); refreshActions()
        } catch { status.stringValue = error.localizedDescription; status.textColor = .systemRed }
    }
    @objc private func addArchiveSources() {
        guard !isWorkerRunning, let window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = true; panel.prompt = "Добавить архивы"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, !self.isWorkerRunning else { return }
            self.openArchiveSources(panel.urls)
        }
    }
    /// Header reading may do I/O; retain the same provider lease and cancellation
    /// contract as searching so close/exit cannot abandon a still-running worker.
    private func openArchiveSources(_ urls: [URL]) {
        guard !isWorkerRunning else { return }
        let token = TransferCancellation(), id = UUID()
        sourceOpeningCancellation = token; generation = id
        isWorkerRunning = true; isSearching = true; workerUsesProvider = true
        status.stringValue = "Чтение источников архивов…"; progress.startAnimation(nil); refreshActions()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var locations: [SearchLocation] = [], failures: [String] = []
            for url in urls {
                if token.isCancelled { break }
                do {
                    let snapshot = try ArchiveReader.open(url, limits: ArchiveLimits(maximumEntries: 100_000,
                        maximumEntryBytes: 256 * 1_048_576, maximumTotalBytes: 256 * 1_048_576), cancellation: token)
                    locations.append(.archive(snapshot, prefix: ""))
                } catch { if !token.isCancelled { failures.append(url.lastPathComponent + ": " + error.localizedDescription) } }
            }
            DispatchQueue.main.async {
                self.sourceOpeningCancellation = nil; self.isWorkerRunning = false
                self.workerUsesProvider = false; self.isSearching = false; self.progress.stopAnimation(nil)
                if self.generation == id {
                    self.appendSources(locations)
                    self.status.stringValue = failures.isEmpty ? "Источники добавлены. Отметьте нужные и нажмите «Найти»." : failures.prefix(10).joined(separator: "\n")
                } else { self.status.stringValue = "Чтение источников остановлено." }
                if self.dropResultsAfterCleanup { self.clearResults(); self.dropResultsAfterCleanup = false; self.table.reloadData() }
                self.refreshActions()
            }
        }
    }

    private var selectedProviderResult: ProviderSearchResult? {
        guard resultRows.indices.contains(table.selectedRow), case .provider(let result) = resultRows[table.selectedRow] else { return nil }
        return result
    }
    private var resultCount: Int { resultRows.count }
    private func clearResults() {
        resultRows.removeAll(keepingCapacity: true)
        providerResults.removeAll(keepingCapacity: true)
        results.removeAll(keepingCapacity: true)
    }
    private var selectedMatch: SearchMatch? {
        guard resultRows.indices.contains(table.selectedRow), case .match(let result) = resultRows[table.selectedRow] else { return nil }
        return result
    }
    private var matches: [SearchMatch] { resultRows.compactMap { if case .match(let match) = $0 { return match }; return nil } }
    @objc private func revealSelected() {
        if let match = selectedMatch { if !isWorkerRunning { onMatchReveal?(match) }; return }
        if let result = selectedProviderResult { if !isWorkerRunning { onProviderReveal?(result) }; return }
        performSelected { onReveal($0) }
    }
    @objc private func viewSelected() {
        if let match = selectedMatch { if !isWorkerRunning && !match.isDirectory && !match.isSymbolicLink { onMatchOpen?(match, false) }; return }
        if selectedProviderResult != nil { openProviderSelection(editable: false); return }
        performSelected { onOpen($0, false) }
    }
    @objc private func editSelected() {
        if let match = selectedMatch { if !isWorkerRunning && !match.isDirectory && !match.isSymbolicLink && match.canEdit { onMatchOpen?(match, true) }; return }
        if selectedProviderResult != nil { openProviderSelection(editable: true); return }
        performSelected { onOpen($0, true) }
    }
    private func openProviderSelection(editable: Bool) {
        guard !isWorkerRunning, let result = selectedProviderResult, !result.isDirectory, !result.isSymbolicLink,
              !editable || canEdit(result) else { return }
        onProviderOpen?(result, editable)
    }
    private func canEdit(_ result: ProviderSearchResult) -> Bool {
        if let snapshot = result.capturedArchiveSnapshot { return !snapshot.isReadOnly }
        return providerSource?.canEdit == true
    }
    private func performSelected(_ action: (SearchResult) -> Void) {
        guard let result = selectedResult else { NSSound.beep(); return }
        do { try result.verifyCurrent(); action(result) }
        catch { status.stringValue = error.localizedDescription; NSSound.beep() }
    }
    @objc private func sendResults() {
        if usesMultipleSources { if !matches.isEmpty { onMatchesToPanel?(matches) }; return }
        guard providerResults.isEmpty, !results.isEmpty else { return }
        onSendToPanel(results)
    }
    private func refreshActions() {
        parameterControls.forEach { $0.isEnabled = !isWorkerRunning }
        roots.isEditable = !isWorkerRunning && !usesMultipleSources && providerSource == nil
        chooseRootButton.isEnabled = !isWorkerRunning && (usesMultipleSources || providerSource == nil)
        followLinks.isEnabled = !isWorkerRunning && (usesMultipleSources ? selectedSources.contains(where: \.isLocalSearchSource) : providerSource == nil)
        modeChanged(); archiveModeChanged()
        startButton.isEnabled = !isWorkerRunning
        cancelButton.isEnabled = isSearching && (sourceOpeningCancellation.map { !$0.isCancelled } ?? (providerCancellation.map { !$0.isCancelled } ?? (cancellation?.isCancelled == false)))
        revealButton.isEnabled = selectedResult != nil
        viewButton.isEnabled = selectedResult != nil
        editButton.isEnabled = selectedResult != nil
        sendButton.isEnabled = providerSource == nil && providerResults.isEmpty && !results.isEmpty
        if providerSource != nil || selectedProviderResult != nil {
            revealButton.isEnabled = !isWorkerRunning && selectedProviderResult != nil
            let regular = selectedProviderResult.map { !$0.isDirectory && !$0.isSymbolicLink } ?? false
            viewButton.isEnabled = !isWorkerRunning && regular
            editButton.isEnabled = !isWorkerRunning && regular && selectedProviderResult.map { canEdit($0) } == true
        }
        if usesMultipleSources {
            sendButton.isEnabled = !matches.isEmpty
            revealButton.isEnabled = !isWorkerRunning && selectedMatch != nil
            let regular = selectedMatch.map { !$0.isDirectory && !$0.isSymbolicLink } ?? false
            viewButton.isEnabled = !isWorkerRunning && regular
            editButton.isEnabled = !isWorkerRunning && regular && selectedMatch?.canEdit == true
            editSourceButton.isEnabled = !isWorkerRunning && sourceRows.indices.contains(sourceTable.selectedRow)
            removeSourceButton.isEnabled = editSourceButton.isEnabled
            for row in sourceRows.indices {
                (sourceTable.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSButton)?.isEnabled = !isWorkerRunning
            }
        }
        if isSearching { status.textColor = .labelColor }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, self.window?.attachedSheet == nil else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if modifiers == [.command], event.keyCode == 36 || event.keyCode == 76 {
                self.startSearch()
                return nil
            }
            if modifiers.isEmpty {
                if self.window?.firstResponder === self.window, self.resultsHaveKeyboardFocus,
                   [UInt16(123), 124, 125, 126, 115, 119, 116, 121].contains(event.keyCode) {
                    self.window?.makeFirstResponder(self.table)
                    self.table.keyDown(with: event)
                    return nil
                }
                switch event.keyCode {
                case 99: self.viewSelected(); return nil // F3
                case 118: self.editSelected(); return nil // F4
                case 53: if self.isSearching { self.cancel(); return nil }
                case 36, 76:
                    if self.resultsHaveKeyboardFocus { self.revealSelected(); return nil }
                default: break
                }
            }
            return event
        }
    }

    private var resultsHaveKeyboardFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder === table { return true }
        // Accessibility row selection may retain the window itself as responder.
        if responder === window { return selectedResult != nil || selectedProviderResult != nil || selectedMatch != nil }
        return (responder as? NSView)?.isDescendant(of: table) == true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === sourceTable ? sourceRows.count : resultCount }
    func tableViewSelectionDidChange(_ notification: Notification) { refreshActions() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === sourceTable { return sourceCell(tableColumn, row: row) }
        guard (0..<resultCount).contains(row) else { return nil }
        let result: SearchDisplayRow
        switch resultRows[row] {
        case .local(let value): result = SearchDisplayRow(value)
        case .provider(let value): result = SearchDisplayRow(value)
        case .match(let value): result = SearchDisplayRow(value)
        }
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("name")
        let field = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField) ?? NSTextField(labelWithString: "")
        field.identifier = identifier
        field.font = .systemFont(ofSize: 11)
        field.lineBreakMode = .byTruncatingMiddle
        switch identifier.rawValue {
        case "name": field.stringValue = (result.isSymbolicLink ? "↗ " : result.isDirectory ? "▸ " : "") + result.name
        case "parent": field.stringValue = (result.path as NSString).deletingLastPathComponent
        case "size": field.stringValue = String(result.size); field.alignment = .right
        case "modified": field.stringValue = result.modified.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? "—"
        default: field.stringValue = result.snippet.map { (result.lineNumber.map { "\($0): " } ?? "") + $0 } ?? ""
        }
        field.toolTip = identifier.rawValue == "snippet" ? result.snippet : result.path
        return field
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }
    private func text(_ value: String, size: CGFloat = 12, bold: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        return field
    }
    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal; stack.spacing = 8
        return stack
    }
    private func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        return stack
    }
    private func scroll(_ view: NSView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = view
        return scroll
    }
    private func configureTextView(_ view: NSTextView, editable: Bool) {
        view.isRichText = false; view.isEditable = editable; view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false; view.isAutomaticSpellingCorrectionEnabled = false
        view.isVerticallyResizable = true; view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 6, height: 5)
    }
}
