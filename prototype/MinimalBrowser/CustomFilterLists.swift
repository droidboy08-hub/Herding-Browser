import Foundation

/// A filter list the user subscribed to by URL.
///
/// The rules themselves live in a file beside this record; only the metadata is
/// in the index, so the index stays small enough to rewrite on every change.
struct CustomFilterList: Codable, Identifiable, Equatable {
    let id: UUID
    /// Set when this list came from the catalogue rather than from a URL the
    /// user typed. Catalogue lists can't be deleted — they're switched off — and
    /// their name comes from the catalogue rather than the file.
    var catalogID: String?
    var url: URL
    /// Taken from the list's own `! Title:` header when it has one, and from the
    /// URL when it doesn't.
    var title: String
    var isEnabled: Bool
    var lastUpdated: Date?
    /// Why the last fetch failed, kept so the row can say so rather than
    /// silently showing stale rules.
    var lastError: String?
    /// Rule count at the last successful fetch, for the row's subtitle.
    var ruleCount: Int

    var fileName: String { "\(id.uuidString).txt" }

    enum DownloadStatus {
        case downloaded(Date)
        case failed(String)
        case pending
    }

    var status: DownloadStatus {
        if let lastError { return .failed(lastError) }
        if let lastUpdated { return .downloaded(lastUpdated) }
        return .pending
    }
}

/// Subscribed filter lists: adding, refreshing, and handing their rules to the
/// engine.
///
/// Filter lists are *data*, which is what makes fetching them over the network
/// compatible with App Store guideline 2.5.2 — the scriptlets that cosmetic
/// filtering injects are code and stay compiled into the binary. Nothing
/// downloaded here is ever evaluated; it is parsed as rules by the engine.
///
/// Main-actor confined: the list is small, every mutation comes from the
/// Content Filtering screen, and the downloads are `async` anyway.
@MainActor
final class CustomFilterListStore {

    static let shared = CustomFilterListStore()

    /// Posted when a list is added, removed, toggled or refreshed.
    static let didChangeNotification = Notification.Name("CustomFilterListStore.didChange")

    private(set) var lists: [CustomFilterList] = []

    /// Lists the user added by URL.
    var subscribed: [CustomFilterList] { lists.filter { $0.catalogID == nil } }

    /// State of a catalogue list: nil when it was never switched on.
    func entry(forCatalogID id: String) -> CustomFilterList? {
        lists.first { $0.catalogID == id }
    }

    func isEnabled(catalogID: String) -> Bool {
        entry(forCatalogID: catalogID)?.isEnabled ?? false
    }

    /// Switch a catalogue list on or off. The first time it's switched on the
    /// rules are fetched; after that the file is kept, so switching back on is
    /// instant and works offline.
    func setEnabled(_ enabled: Bool, catalogEntry: CatalogFilterList) async throws {
        if let existing = entry(forCatalogID: catalogEntry.id) {
            setEnabled(enabled, for: existing)
            // A list switched on that never downloaded — the first attempt
            // failed — should try again rather than sit there enabled and empty.
            if enabled, existing.lastUpdated == nil {
                try await refetch(existing)
            }
            return
        }
        guard enabled else { return }

        var list = CustomFilterList(id: UUID(), catalogID: catalogEntry.id,
                                    url: catalogEntry.url, title: catalogEntry.title,
                                    isEnabled: true, lastUpdated: nil,
                                    lastError: nil, ruleCount: 0)
        try await download(into: &list)
        lists.append(list)
        save()
        notify()
    }

    /// Fetch a list that is already in the index, surfacing the error to the
    /// caller rather than only recording it on the row.
    private func refetch(_ list: CustomFilterList) async throws {
        guard let index = lists.firstIndex(where: { $0.id == list.id }) else { return }
        var copy = lists[index]
        do {
            try await download(into: &copy)
        } catch {
            copy.lastError = error.localizedDescription
            if let current = lists.firstIndex(where: { $0.id == copy.id }) { lists[current] = copy }
            save()
            notify()
            throw error
        }
        if let current = lists.firstIndex(where: { $0.id == copy.id }) { lists[current] = copy }
        save()
        notify()
    }

    /// Switch on whatever the catalogue marks as on for a new install, once.
    /// Failures are ignored: a first launch without a network shouldn't leave
    /// the app in a state where these never come back — `refreshStale` retries.
    func enableCatalogDefaultsIfNeeded() async {
        // Which defaults have been applied, not merely *whether* any have.
        //
        // The old flag was a single bool set on first launch, which meant a
        // list promoted to a default in a later version was never switched on
        // for anyone who had already run the app — including the community
        // site fixes, which stopped being bundled and became a default
        // subscription instead. Recording the ids applies each new one once,
        // and still never re-enables something the user has since turned off.
        let key = "filterCatalog.appliedDefaults"
        var applied = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])

        // Anyone upgrading from the single-flag version has already had the
        // defaults of *that* version applied; record them so they aren't
        // switched back on after being turned off.
        if UserDefaults.standard.bool(forKey: "filterCatalog.defaultsApplied"), applied.isEmpty {
            applied = ["core-ad-filters",
                       "AC023D22-AE88-4060-A978-4FEEEC4221693",
                       "2F3DCE16-A19A-493C-A88F-2E110FBD37D6"]
        }

        for entry in FilterListCatalog.entries
        where entry.defaultEnabled && !applied.contains(entry.id) {
            try? await setEnabled(true, catalogEntry: entry)
            applied.insert(entry.id)
        }
        UserDefaults.standard.set(Array(applied), forKey: key)
    }

    /// A list that hasn't been checked in this long is refetched at launch. A
    /// day matches what the lists themselves ask for in their `! Expires`
    /// headers, and is far more often than a rule change actually matters.
    private let refreshInterval: TimeInterval = 24 * 60 * 60

    /// Downloads use their own session: no cookies, nothing written to the
    /// shared cache. A filter list is a public file and the request should say
    /// nothing about who is asking for it.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    private let directory: URL
    private let indexURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        directory = support.appendingPathComponent("CustomFilterLists", isDirectory: true)
        indexURL = directory.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        load()
    }

    // MARK: - Reading

    /// Rule text of every enabled list, for the engine build. Reads from disk
    /// rather than holding megabytes of rules in memory between builds.
    func enabledRules() -> [String] {
        lists.filter(\.isEnabled).compactMap {
            try? String(contentsOf: directory.appendingPathComponent($0.fileName),
                        encoding: .utf8)
        }
    }

    /// Identifies the current set of enabled lists *and their contents*, so the
    /// engine rebuilds when a list is toggled or a refresh brings new rules.
    var signature: String {
        lists.filter(\.isEnabled)
            .map { "\($0.id.uuidString):\($0.lastUpdated?.timeIntervalSince1970 ?? 0)" }
            .joined(separator: "|")
    }

    // MARK: - Editing

    /// Subscribe to a list. Fetches it immediately: a URL that doesn't produce a
    /// filter list should fail here, in front of the user, rather than being
    /// added as a row that never works.
    func add(url: URL) async throws {
        guard url.scheme == "https" || url.scheme == "http" else {
            throw StoreError.notAWebURL
        }
        guard !lists.contains(where: { $0.url == url }) else {
            throw StoreError.alreadySubscribed
        }

        var list = CustomFilterList(id: UUID(), catalogID: nil, url: url,
                                    title: Self.fallbackTitle(for: url),
                                    isEnabled: true, lastUpdated: nil,
                                    lastError: nil, ruleCount: 0)
        try await download(into: &list)
        lists.append(list)
        save()
        notify()
    }

    func remove(_ list: CustomFilterList) {
        lists.removeAll { $0.id == list.id }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(list.fileName))
        save()
        notify()
    }

    func setEnabled(_ enabled: Bool, for list: CustomFilterList) {
        guard let index = lists.firstIndex(where: { $0.id == list.id }) else { return }
        lists[index].isEnabled = enabled
        save()
        notify()
    }

    /// Refetch every list in use, whether or not it's due. For the Update Lists
    /// row and pull-to-refresh on the Content Filtering screen.
    func refreshAll() async {
        for list in lists where list.isEnabled {
            await refresh(list, force: true)
        }
    }

    /// Refetch only what has gone stale. Called at launch; failures leave the
    /// last good copy in place, because stale rules beat no rules. Lists that
    /// are switched off aren't fetched at all — nothing reads them.
    func refreshStale() async {
        for list in lists where list.isEnabled {
            await refresh(list, force: false)
        }
    }

    private func refresh(_ list: CustomFilterList, force: Bool) async {
        guard let index = lists.firstIndex(where: { $0.id == list.id }) else { return }
        if !force, let updated = lists[index].lastUpdated,
           Date().timeIntervalSince(updated) < refreshInterval {
            return
        }
        var copy = lists[index]
        do {
            try await download(into: &copy)
        } catch {
            copy.lastError = error.localizedDescription
        }
        // The array can have moved while the fetch was in flight.
        guard let current = lists.firstIndex(where: { $0.id == copy.id }) else { return }
        lists[current] = copy
        save()
        notify()
    }

    // MARK: - Downloading

    private func download(into list: inout CustomFilterList) async throws {
        let (data, response) = try await session.data(from: list.url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw StoreError.httpStatus(http.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw StoreError.notText
        }
        // A URL that returns a web page rather than a list is the common mistake
        // — someone pastes the GitHub page instead of the raw file. Catch it here
        // rather than feeding markup to the parser.
        let head = text.prefix(2048).lowercased()
        guard !head.contains("<!doctype html"), !head.contains("<html") else {
            throw StoreError.notAFilterList
        }
        let rules = text.split(separator: "\n").filter {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return !line.isEmpty && !line.hasPrefix("!") && !line.hasPrefix("[")
        }
        guard !rules.isEmpty else { throw StoreError.notAFilterList }

        try text.write(to: directory.appendingPathComponent(list.fileName),
                       atomically: true, encoding: .utf8)
        // A catalogue list keeps the catalogue's name ("Cookie notice blocker"),
        // not the one in the file's header ("EasyList Cookie") — the second is
        // already the row's subtitle.
        if list.catalogID == nil, let title = Self.declaredTitle(in: text) {
            list.title = title
        }
        list.ruleCount = rules.count
        list.lastUpdated = Date()
        list.lastError = nil
    }

    /// `! Title: EasyList` — the header every well-formed list carries.
    private static func declaredTitle(in text: String) -> String? {
        for line in text.prefix(4096).split(separator: "\n").prefix(20) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("! title:") else { continue }
            let title = trimmed.dropFirst("! title:".count).trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : title
        }
        return nil
    }

    private static func fallbackTitle(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? (url.host ?? url.absoluteString) : name
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let stored = try? JSONDecoder().decode([CustomFilterList].self, from: data) else {
            return
        }
        lists = stored
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(lists) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        // Rules changed, so whatever is built from them is stale.
        NotificationCenter.default.post(name: .contentBlockingChanged, object: nil)
    }

    enum StoreError: LocalizedError {
        case notAWebURL
        case alreadySubscribed
        case httpStatus(Int)
        case notText
        case notAFilterList

        var errorDescription: String? {
            switch self {
            case .notAWebURL:       return "That isn't an http or https address."
            case .alreadySubscribed: return "You're already subscribed to that list."
            case .httpStatus(let code):
                return "The server answered \(code) "
                     + "(\(HTTPURLResponse.localizedString(forStatusCode: code)))."
            case .notText:          return "That file isn't text."
            case .notAFilterList:
                return "That URL doesn't return filter rules. If it's a page on a "
                     + "code host, use the raw file link."
            }
        }
    }
}
