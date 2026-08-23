import Foundation
import WebKit

/// Everything the browser stores, behind one object.
///
/// The point of a profile is that a private session is the *same code* pointed at
/// different storage: an in-memory database, a tab store that never writes, and a
/// non-persistent `WKWebsiteDataStore`. Nothing downstream needs an `isPrivate`
/// branch — it asks the profile for storage and gets whichever kind it has.
protocol Profile: AnyObject {
    var isPrivate: Bool { get }
    var db: BrowserDB { get }
    var history: SQLiteHistory { get }
    var tabManager: TabManager { get }
    /// Injected into `WKWebViewConfiguration`: `.default()` for a regular
    /// profile, `.nonPersistent()` for private browsing.
    var websiteDataStore: WKWebsiteDataStore { get }

    func shutdown()
    /// Wipe this profile: history, tabs and everything WebKit cached for it.
    func clearAllBrowsingData(completion: (() -> Void)?)
}

extension Profile {
    /// The common case, where nothing needs to wait on the store finishing.
    func clearAllBrowsingData() { clearAllBrowsingData(completion: nil) }
}

final class BrowserProfile: Profile {

    let localName: String
    let isPrivate: Bool

    let db: BrowserDB
    let history: SQLiteHistory
    let tabManager: TabManager

    private let tabStore: TabManagerStore
    private let directory: URL

    /// Held, not computed: every `.nonPersistent()` call mints a *different*
    /// store, so a computed property would hand out a fresh empty one on each
    /// access and the private session would lose its own cookies.
    let websiteDataStore: WKWebsiteDataStore

    /// - Parameters:
    ///   - localName: the profile's folder under Application Support. Multiple
    ///     named profiles can coexist without knowing about each other.
    ///   - isPrivate: in-memory database, no session file, non-persistent
    ///     website data.
    init(localName: String = "profile.default", isPrivate: Bool = false) {
        self.localName = localName
        self.isPrivate = isPrivate
        websiteDataStore = isPrivate ? .nonPersistent() : .default()

        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        directory = support.appendingPathComponent(localName, isDirectory: true)
        if !isPrivate {
            try? FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)
            Self.adoptPreProfileDatabase(into: directory, from: support)
        }

        db = BrowserDB(filename: isPrivate ? ":memory:" : "browser.db",
                       schema: BrowserSchema(),
                       directory: directory)
        history = SQLiteHistory(db: db)
        tabStore = TabManagerStore(directory: directory, isEphemeral: isPrivate)
        tabManager = TabManager(store: tabStore, isPrivate: isPrivate)

        if !isPrivate {
            importLegacyHistoryJSON(from: support)
            history.expireOldVisits()
        }
    }

    /// Flush anything that must survive the process going away. Called when the
    /// app is backgrounded, which is the last reliable moment we get.
    func shutdown() {
        tabManager.preserveTabs()
    }

    /// Wipe browsing data for this profile — history, tabs and everything WebKit
    /// cached.
    func clearAllBrowsingData(completion: (() -> Void)? = nil) {
        history.clear()
        tabManager.removeAllTabs()
        websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                    modifiedSince: .distantPast) {
            completion?()
        }
    }

    // MARK: - Migrations into the profile directory

    /// The database used to sit loose in Application Support, before profiles
    /// existed. Move it (with its WAL sidecars) into the profile folder so the
    /// schema migration finds the existing history instead of starting empty.
    private static func adoptPreProfileDatabase(into directory: URL, from support: URL) {
        let destination = directory.appendingPathComponent("browser.db")
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }

        let legacy = support.appendingPathComponent("history.sqlite")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }

        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: legacy.path + suffix)
            let to = URL(fileURLWithPath: destination.path + suffix)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            try? FileManager.default.moveItem(at: from, to: to)
        }
        log("[Profile] adopted the pre-profile history database")
    }

    /// Before there was any database, history was a flat JSON array. Import it
    /// once, then rename rather than delete — if the import ever goes wrong the
    /// original is still there.
    private func importLegacyHistoryJSON(from support: URL) {
        struct LegacyHistoryEntry: Codable {
            let url: URL
            let title: String
            let date: Date
        }
        let legacy = support.appendingPathComponent("history.json")
        guard FileManager.default.fileExists(atPath: legacy.path),
              let data = try? Data(contentsOf: legacy),
              let rows = try? JSONDecoder().decode([LegacyHistoryEntry].self, from: data)
        else { return }

        history.importLegacy(rows.map { ($0.url, $0.title, $0.date) })
        try? FileManager.default.moveItem(
            at: legacy, to: support.appendingPathComponent("history.json.imported"))
    }
}
