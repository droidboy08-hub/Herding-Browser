import Foundation

/// Codable snapshot of a tab. The favicon isn't persisted — it re-fetches when
/// the tab loads.
private struct TabRecord: Codable {
    let id: UUID
    let title: String
    let url: URL
}

/// Saves/restores the open tabs + current tab across launches (UserDefaults).
enum SessionStore {
    private static let tabsKey = "session.tabs.v1"
    private static let currentKey = "session.currentTab.v1"

    static func save(tabs: [Tab], current: UUID?) {
        let records = tabs.map { TabRecord(id: $0.id, title: $0.title, url: $0.url) }
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: tabsKey)
        }
        UserDefaults.standard.set(current?.uuidString, forKey: currentKey)
    }

    static func load() -> (tabs: [Tab], current: UUID?) {
        guard let data = UserDefaults.standard.data(forKey: tabsKey),
              let records = try? JSONDecoder().decode([TabRecord].self, from: data) else {
            return ([], nil)
        }
        let tabs = records.map { Tab(id: $0.id, title: $0.title, url: $0.url) }
        let current = UserDefaults.standard.string(forKey: currentKey).flatMap(UUID.init)
        return (tabs, current)
    }
}

/// One visited page.
struct HistoryEntry: Codable, Identifiable {
    var id: URL { url }
    let url: URL
    let title: String
    let date: Date
}

/// Persistent visit history (newest first), stored as JSON in Application Support.
final class HistoryStore {
    static let shared = HistoryStore()

    private(set) var entries: [HistoryEntry] = []
    private let cap = 1000
    private let fileURL: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")
        load()
    }

    func record(url: URL, title: String) {
        guard url.scheme?.hasPrefix("http") == true else { return }
        entries.removeAll { $0.url == url }               // keep one entry per URL, most-recent
        entries.insert(HistoryEntry(url: url, title: title, date: Date()), at: 0)
        if entries.count > cap { entries.removeLast(entries.count - cap) }
        save()
    }

    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.url == entry.url }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
