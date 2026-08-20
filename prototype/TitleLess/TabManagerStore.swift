import Foundation

/// The serialized form of a tab. Deliberately narrow: identity, where it was,
/// what it was called, and WebKit's opaque session blob. Favicons and page
/// snapshots are regenerable and live in the caches directory instead.
private struct StoredTab: Codable {
    let id: UUID
    var title: String
    var url: URL
    var sessionState: Data?
    var lastUsed: Date
}

/// Order and selection, kept apart from the tabs themselves so reordering or
/// switching tabs doesn't rewrite any page state.
private struct SessionIndex: Codable {
    var order: [UUID]
    var selected: UUID?
    var savedAt: Date
}

/// Persists the tab session to disk as one JSON file per tab plus a small index.
///
/// Tabs are session state — read and written whole, never queried — so they stay
/// out of SQLite. But a single `session.json` means every change rewrites every
/// tab: switching tabs re-encodes fifty pages' session blobs. Splitting per tab
/// makes each write proportional to what actually changed, which is what a
/// row-based store buys you, without a database.
///
/// Writes are coalesced: rapid updates to the same tab collapse into one write.
/// `preserveAll` flushes immediately, for the moment the app is backgrounded.
final class TabManagerStore {

    private let directory: URL
    private let tabsDirectory: URL
    private let indexURL: URL
    private let legacyArchiveURL: URL
    private let isEphemeral: Bool
    private let queue = DispatchQueue(label: "browser.tabstore", qos: .utility)

    /// How long to sit on a change before writing, so a burst of updates to one
    /// tab costs one write.
    private let coalescingDelay: TimeInterval = 0.5

    // Queue-confined state.
    private var pendingTabs: [UUID: StoredTab] = [:]
    private var pendingIndex: SessionIndex?
    private var flushScheduled = false

    /// A private profile passes `isEphemeral: true`: `TabManager` keeps the
    /// session in memory and nothing is ever written to disk.
    init(directory: URL, isEphemeral: Bool = false) {
        self.directory = directory
        self.isEphemeral = isEphemeral
        tabsDirectory = directory.appendingPathComponent("tabs", isDirectory: true)
        indexURL = directory.appendingPathComponent("session-index.json")
        legacyArchiveURL = directory.appendingPathComponent("session.json")
        if !isEphemeral {
            try? FileManager.default.createDirectory(at: tabsDirectory,
                                                     withIntermediateDirectories: true)
        }
    }

    // MARK: - Granular writes

    /// One tab changed — title, URL or back/forward state. Touches that tab's
    /// file only.
    func update(_ tab: Tab) {
        guard !isEphemeral else { return }
        let stored = StoredTab(id: tab.id, title: tab.title, url: tab.url,
                               sessionState: tab.sessionState, lastUsed: tab.lastUsed)
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingTabs[tab.id] = stored
            self.scheduleFlush()
        }
    }

    /// Order or selection changed. Touches the index only — no page state is
    /// rewritten to move a tab or switch to one.
    func saveOrder(_ tabs: [Tab], selected: UUID?) {
        guard !isEphemeral else { return }
        let index = SessionIndex(order: tabs.map(\.id), selected: selected, savedAt: Date())
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingIndex = index
            self.scheduleFlush()
        }
    }

    /// A tab was closed: drop its file and forget any pending write for it.
    func remove(tabID: UUID) {
        guard !isEphemeral else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingTabs[tabID] = nil
            try? FileManager.default.removeItem(at: self.fileURL(for: tabID))
        }
    }

    /// Write everything now, pending changes included. For app backgrounding —
    /// the last reliable moment before the system can kill us.
    func preserveAll(_ tabs: [Tab], selected: UUID?) {
        guard !isEphemeral else { return }
        let stored = tabs.map {
            StoredTab(id: $0.id, title: $0.title, url: $0.url,
                      sessionState: $0.sessionState, lastUsed: $0.lastUsed)
        }
        let index = SessionIndex(order: tabs.map(\.id), selected: selected, savedAt: Date())
        queue.async { [weak self] in
            guard let self else { return }
            for tab in stored { self.pendingTabs[tab.id] = tab }
            self.pendingIndex = index
            self.flush()
            self.pruneOrphans(keeping: Set(stored.map(\.id)))
        }
    }

    func clearArchive() {
        guard !isEphemeral else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingTabs.removeAll()
            self.pendingIndex = nil
            try? FileManager.default.removeItem(at: self.tabsDirectory)
            try? FileManager.default.removeItem(at: self.indexURL)
            try? FileManager.default.createDirectory(at: self.tabsDirectory,
                                                     withIntermediateDirectories: true)
        }
    }

    // MARK: - Reading

    /// Read the session back. Synchronous: it runs once, at launch, before there
    /// is anything on screen to block.
    func restoreTabs() -> (tabs: [Tab], selected: UUID?) {
        guard !isEphemeral else { return ([], nil) }

        migrateSingleFileArchiveIfNeeded()

        guard let indexData = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(SessionIndex.self, from: indexData) else {
            return restoreLegacyUserDefaults()
        }

        // The index defines order; a tab whose file is missing or corrupt is
        // skipped rather than failing the whole restore.
        let tabs: [Tab] = index.order.compactMap { id in
            guard let data = try? Data(contentsOf: fileURL(for: id)),
                  let stored = try? JSONDecoder().decode(StoredTab.self, from: data) else {
                return nil
            }
            return Tab(id: stored.id, title: stored.title, url: stored.url,
                       sessionState: stored.sessionState, lastUsed: stored.lastUsed)
        }
        let selected = tabs.contains { $0.id == index.selected } ? index.selected : tabs.last?.id
        return (tabs, selected)
    }

    // MARK: - Flushing

    /// Must run on `queue`.
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + coalescingDelay) { [weak self] in
            self?.flush()
        }
    }

    /// Must run on `queue`. Writes atomically — an interrupted write can't leave
    /// a half-file that loses the session on next launch.
    private func flush() {
        flushScheduled = false
        let encoder = JSONEncoder()

        for (id, tab) in pendingTabs {
            guard let data = try? encoder.encode(tab) else { continue }
            do {
                try data.write(to: fileURL(for: id), options: .atomic)
            } catch {
                log("[TabManagerStore] write failed for \(id): \(error.localizedDescription)")
            }
        }
        pendingTabs.removeAll()

        if let index = pendingIndex, let data = try? encoder.encode(index) {
            try? data.write(to: indexURL, options: .atomic)
            pendingIndex = nil
        }
    }

    /// Delete tab files the index no longer references — a crash between the two
    /// writes can leave one behind.
    private func pruneOrphans(keeping ids: Set<UUID>) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tabsDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  !ids.contains(id) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func fileURL(for id: UUID) -> URL {
        tabsDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: - Migrations

    /// Split the previous single-file `session.json` into per-tab files. Runs
    /// once; the old file is renamed rather than deleted.
    private func migrateSingleFileArchiveIfNeeded() {
        guard !FileManager.default.fileExists(atPath: indexURL.path),
              FileManager.default.fileExists(atPath: legacyArchiveURL.path) else { return }

        struct LegacyArchive: Codable {
            struct LegacyTab: Codable {
                let id: UUID
                let title: String
                let url: URL
                let sessionState: Data?
                let lastUsed: Date
            }
            let tabs: [LegacyTab]
            let selected: UUID?
        }
        guard let data = try? Data(contentsOf: legacyArchiveURL),
              let archive = try? JSONDecoder().decode(LegacyArchive.self, from: data) else { return }

        let encoder = JSONEncoder()
        for tab in archive.tabs {
            let stored = StoredTab(id: tab.id, title: tab.title, url: tab.url,
                                   sessionState: tab.sessionState, lastUsed: tab.lastUsed)
            if let encoded = try? encoder.encode(stored) {
                try? encoded.write(to: fileURL(for: tab.id), options: .atomic)
            }
        }
        let index = SessionIndex(order: archive.tabs.map(\.id),
                                 selected: archive.selected, savedAt: Date())
        if let encoded = try? encoder.encode(index) {
            try? encoded.write(to: indexURL, options: .atomic)
        }
        try? FileManager.default.moveItem(
            at: legacyArchiveURL,
            to: directory.appendingPathComponent("session.json.migrated"))
        log("[TabManagerStore] split \(archive.tabs.count) tabs out of the single-file archive")
    }

    /// Before any file store existed, tabs lived in UserDefaults. Read them once
    /// so an update doesn't wipe the user's open tabs, then retire the keys.
    private func restoreLegacyUserDefaults() -> (tabs: [Tab], selected: UUID?) {
        struct LegacyTab: Codable {
            let id: UUID
            let title: String
            let url: URL
        }
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: "session.tabs.v1"),
              let records = try? JSONDecoder().decode([LegacyTab].self, from: data) else {
            return ([], nil)
        }
        let selected = defaults.string(forKey: "session.currentTab.v1").flatMap(UUID.init)
        let tabs = records.map { Tab(id: $0.id, title: $0.title, url: $0.url) }

        defaults.removeObject(forKey: "session.tabs.v1")
        defaults.removeObject(forKey: "session.currentTab.v1")
        log("[TabManagerStore] migrated \(tabs.count) tabs out of UserDefaults")

        preserveAll(tabs, selected: selected)
        return (tabs, selected)
    }
}
