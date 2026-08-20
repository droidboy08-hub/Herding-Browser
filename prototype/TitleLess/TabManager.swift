import UIKit

protocol TabManagerDelegate: AnyObject {
    /// The tab list itself changed — added, closed, reordered, retitled.
    func tabManagerDidChangeTabs(_ manager: TabManager)
    /// A different tab became current. `previous` is nil on the first selection.
    func tabManager(_ manager: TabManager, didSelect tab: Tab?, previous: Tab?)
}

/// Owns the open tabs in memory and tells `TabManagerStore` when to write them
/// out. Nothing here touches SQLite: tabs are session state, read and written
/// whole, and belong in a file.
///
/// The browser reuses a single `WKWebView`, so `TabManager` holds no web views —
/// it holds what's needed to put one back on a page: URL, title, and WebKit's
/// session blob.
final class TabManager {

    weak var delegate: TabManagerDelegate?

    private(set) var tabs: [Tab] = []
    private(set) var selectedTabID: UUID?

    private let store: TabManagerStore
    let isPrivate: Bool

    var selectedTab: Tab? {
        guard let selectedTabID else { return nil }
        return tabs.first { $0.id == selectedTabID }
    }

    var count: Int { tabs.count }

    init(store: TabManagerStore, isPrivate: Bool = false) {
        self.store = store
        self.isPrivate = isPrivate
    }

    // MARK: - Restore

    /// Load the persisted session. Snapshots come from the caches directory, and
    /// any snapshot whose tab is gone is pruned.
    func restore() {
        let archive = store.restoreTabs()
        tabs = archive.tabs
        selectedTabID = archive.selected

        // Sessions written before `updateSelectedTab` refused about:blank can
        // hold tabs pointing at nothing. They can't be opened — selecting one
        // shows a white page — so drop them here rather than letting the user
        // keep tapping a dead card.
        let broken = tabs.filter { !$0.url.isWebPage }
        if !broken.isEmpty {
            tabs.removeAll { !$0.url.isWebPage }
            for tab in broken {
                SnapshotStore.delete(for: tab.id)
                store.remove(tabID: tab.id)
            }
            log("[TabManager] dropped \(broken.count) tab(s) with no usable URL")
        }

        for index in tabs.indices {
            tabs[index].snapshot = SnapshotStore.load(for: tabs[index].id)
        }
        SnapshotStore.prune(keeping: Set(tabs.map(\.id)))

        // A selection pointing at a tab that didn't survive would strand the UI.
        if let id = selectedTabID, !tabs.contains(where: { $0.id == id }) {
            selectedTabID = tabs.last?.id
        }
        // Only write the index back if the restore had to repair something;
        // an intact session is left exactly as it was found.
        if !broken.isEmpty {
            store.saveOrder(tabs, selected: selectedTabID)
        }
        delegate?.tabManagerDidChangeTabs(self)
    }

    // MARK: - Mutating the list

    @discardableResult
    func addTab(url: URL, title: String? = nil, select: Bool = true) -> Tab {
        let tab = Tab(title: title ?? url.host ?? url.absoluteString, url: url)
        // Newest first. Appending put each new tab at the bottom of a list you
        // then had to scroll to reach it — and the tab you just opened is the
        // one you are most likely to want back.
        tabs.insert(tab, at: 0)
        if select {
            let previous = selectedTab
            selectedTabID = tab.id
            delegate?.tabManager(self, didSelect: tab, previous: previous)
        }
        // One new tab file, plus the index. No other tab is touched.
        store.update(tab)
        store.saveOrder(tabs, selected: selectedTabID)
        delegate?.tabManagerDidChangeTabs(self)
        return tab
    }

    func selectTab(id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }), id != selectedTabID else { return }
        let previous = selectedTab
        selectedTabID = id
        touch(id)
        delegate?.tabManager(self, didSelect: tab, previous: previous)
        // Switching tabs is an index change — no page state is rewritten.
        store.saveOrder(tabs, selected: selectedTabID)
        delegate?.tabManagerDidChangeTabs(self)
    }

    /// Close a tab. Selection falls back to the neighbour, which is what every
    /// browser does — closing tab 3 of 5 should not dump you on the last tab.
    func removeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedTabID == id
        tabs.remove(at: index)
        SnapshotStore.delete(for: id)

        if wasSelected {
            let neighbour = tabs.indices.contains(index) ? tabs[index] : tabs.last
            let previous: Tab? = nil        // the old tab is gone
            selectedTabID = neighbour?.id
            delegate?.tabManager(self, didSelect: neighbour, previous: previous)
        }
        // Delete that one tab's file, then rewrite the index.
        store.remove(tabID: id)
        store.saveOrder(tabs, selected: selectedTabID)
        delegate?.tabManagerDidChangeTabs(self)
    }

    func removeAllTabs() {
        for tab in tabs { SnapshotStore.delete(for: tab.id) }
        tabs.removeAll()
        selectedTabID = nil
        delegate?.tabManager(self, didSelect: nil, previous: nil)
        store.clearArchive()
        delegate?.tabManagerDidChangeTabs(self)
    }

    func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from), tabs.indices.contains(to), from != to else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
        // Reordering is purely an index write.
        store.saveOrder(tabs, selected: selectedTabID)
        delegate?.tabManagerDidChangeTabs(self)
    }

    // MARK: - Updating the selected tab

    /// Fold in whatever the web view now knows about the current page.
    ///
    /// A tab's URL is where it goes when the user opens it again, so only a real
    /// page may become one. The web view passes through about:blank whenever a
    /// session restore comes back empty or a tab is torn down, and recording
    /// that would leave the tab pointing at nothing for good — every later open
    /// showing a white page with no way back to the site.
    func updateSelectedTab(url: URL? = nil,
                           title: String? = nil,
                           sessionState: Data? = nil) {
        guard let index = selectedIndex else { return }
        if let url, url.isWebPage { tabs[index].url = url }
        if let title, !title.isEmpty { tabs[index].title = title }
        if let sessionState { tabs[index].sessionState = sessionState }
        tabs[index].lastUsed = Date()
        // Only this tab's file. Repeated updates while a page loads coalesce
        // into one write.
        store.update(tabs[index])
        delegate?.tabManagerDidChangeTabs(self)
    }

    /// Favicons and snapshots change constantly and are cheap to regenerate, so
    /// they refresh the UI without forcing a session write.
    func setIcon(_ icon: UIImage?, for id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].icon = icon
        delegate?.tabManagerDidChangeTabs(self)
    }

    func setSnapshot(_ snapshot: UIImage?, for id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].snapshot = snapshot
        if let snapshot { SnapshotStore.save(snapshot, for: id) }
        delegate?.tabManagerDidChangeTabs(self)
    }

    /// Store the back/forward list for a specific tab — used when switching away
    /// from it, by which time it may no longer be the selected one.
    func setSessionState(_ state: Data?, for id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].sessionState = state
        store.update(tabs[index])       // that tab's file only, no UI change
    }

    // MARK: - Persistence

    /// Flush everything, pending coalesced writes included. Mutations write
    /// themselves; this is for the moment the app is backgrounded, when the
    /// system may kill us before a coalesced write lands.
    func preserveTabs() {
        store.preserveAll(tabs, selected: selectedTabID)
    }

    private var selectedIndex: Int? {
        guard let selectedTabID else { return nil }
        return tabs.firstIndex { $0.id == selectedTabID }
    }

    private func touch(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].lastUsed = Date()
    }

    private func commit(notify: Bool = true) {
        preserveTabs()
        if notify { delegate?.tabManagerDidChangeTabs(self) }
    }
}
