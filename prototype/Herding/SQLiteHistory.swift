import Foundation

/// How a visit came about. Same classification Chromium and Firefox keep, and for
/// the same two reasons: ranking weights differ per type, and the UI wants to
/// tell a page you typed from one a redirect dragged you through.
enum VisitTransition: Int {
    case link = 0           // followed a link
    case typed = 1          // entered in the start box
    case reload = 2
    case formSubmit = 3
    case backForward = 4
    case redirect = 5       // landed here via a server redirect
    case sameDocument = 6   // history.pushState — an SPA route change

    /// Ranking weight. Typing a URL is the strongest signal of intent; a reload
    /// or a redirect says almost nothing.
    var weight: Double {
        switch self {
        case .typed:        return 2000
        case .link:         return 1000
        case .formSubmit:   return 700
        case .sameDocument: return 400
        case .backForward:  return 100
        case .reload:       return 100
        case .redirect:     return 50
        }
    }
}

/// One row in the History list: a single visit joined to the page it was a visit
/// to. Two visits to the same URL are two entries sharing a `siteID`.
struct HistoryEntry: Identifiable, Equatable {
    let id: Int64            // visit id
    let siteID: Int64
    let url: URL
    let title: String
    let date: Date
    let visitCount: Int
}

/// The app's history API, over `BrowserDB`.
///
/// Writes go to the database queue and return immediately — recording a visit
/// must never make a swipe navigation wait on the disk. Reads are synchronous
/// because the panel needs rows to render. Every mutation posts
/// `didChangeNotification` on the main thread.
final class SQLiteHistory {

    static let didChangeNotification = Notification.Name("SQLiteHistory.didChange")

    private let db: BrowserDB

    /// Visits older than this expire at launch. Chrome keeps ~90 days, Safari
    /// defaults to a year; a year is the friendlier default.
    private let retention: TimeInterval = 365 * 24 * 3600

    /// The visit the next one descends from. Lives on the database queue, so the
    /// caller never has to wait for an id to chain the next visit to.
    private var lastVisitID: Int64?

    init(db: BrowserDB) {
        self.db = db
    }

    // MARK: - Recording

    /// Log a visit. Returns immediately; the write lands on the database queue.
    func recordVisit(url: URL, title: String, transition: VisitTransition) {
        // Only real web pages. `about:blank`, `data:` error pages and custom
        // schemes are noise, and every browser filters them the same way.
        guard url.scheme?.hasPrefix("http") == true else { return }
        let now = Date().timeIntervalSince1970
        let host = url.host ?? ""

        db.run({ [weak self] connection in
            guard let self else { return }

            // Upsert the page. An empty title must not overwrite a good one —
            // titles resolve after the navigation commits, so the first write
            // for a page is usually blank.
            connection.executeChange("""
                INSERT INTO \(TableNames.historyItems)
                    (guid, url, title, host, visit_count, typed_count, last_visit_date, local_modified)
                VALUES (?, ?, ?, ?, 1, ?, ?, ?)
                ON CONFLICT(url) DO UPDATE SET
                    visit_count     = visit_count + 1,
                    typed_count     = typed_count + excluded.typed_count,
                    last_visit_date = excluded.last_visit_date,
                    local_modified  = excluded.local_modified,
                    title           = CASE WHEN excluded.title <> ''
                                           THEN excluded.title ELSE \(TableNames.historyItems).title END
                """, args: [UUID().uuidString, url.absoluteString, title, host,
                            transition == .typed ? 1 : 0, now, now])

            guard let siteID = self.siteID(for: url, in: connection) else { return }

            connection.executeChange("""
                INSERT INTO \(TableNames.historyVisits) (site_id, date, type, from_visit, is_local)
                VALUES (?, ?, ?, ?, 1)
                """, args: [siteID, now, transition.rawValue, self.lastVisitID])

            self.lastVisitID = connection.lastInsertedRowID
            self.updateFrecency(siteID: siteID, in: connection)
        }, then: { [weak self] in
            self?.notifyChange()
        })
    }

    /// Typing a new address starts a fresh chain — the next visit didn't descend
    /// from whatever was on screen before.
    func resetVisitChain() {
        db.run { [weak self] _ in self?.lastVisitID = nil }
    }

    /// Patch in the title once the page reports one; the visit was already
    /// recorded at commit.
    func updateTitle(url: URL, title: String) {
        guard url.scheme?.hasPrefix("http") == true, !title.isEmpty else { return }
        db.run({ connection in
            connection.executeChange("""
                UPDATE \(TableNames.historyItems) SET title = ?, local_modified = ?
                WHERE url = ? AND title <> ?
                """, args: [title, Date().timeIntervalSince1970, url.absoluteString, title])
        }, then: { [weak self] in
            self?.notifyChange()
        })
    }

    // MARK: - Reading

    /// Newest visits first — one row per visit, which is what the visits table
    /// holds.
    ///
    /// With `grouping` on, consecutive visits to the same URL collapse into a
    /// single row (a `LAG` window over the ordered visits). That's display only:
    /// every visit is stored either way. Over-fetching 4× the limit before
    /// collapsing keeps a run of repeats from starving the page.
    func recentEntries(limit: Int = 500,
                       matching query: String = "",
                       grouping: Bool = false) -> [HistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let filtered = !trimmed.isEmpty
        let filter = filtered ? "AND (i.url LIKE ?1 OR i.title LIKE ?1)" : ""
        let sql: String
        if grouping {
            sql = """
                SELECT * FROM (
                    SELECT v.id, i.id AS site_id, i.url, i.title, v.date, i.visit_count,
                           LAG(i.url) OVER (ORDER BY v.date DESC) AS prev_url
                    FROM \(TableNames.historyVisits) v
                    JOIN \(TableNames.historyItems) i ON i.id = v.site_id
                    WHERE i.is_deleted = 0 \(filter)
                    ORDER BY v.date DESC
                    LIMIT \(max(limit, 1) * 4)
                )
                WHERE prev_url IS NULL OR prev_url <> url
                LIMIT \(max(limit, 1))
                """
        } else {
            sql = """
                SELECT v.id, i.id AS site_id, i.url, i.title, v.date, i.visit_count
                FROM \(TableNames.historyVisits) v
                JOIN \(TableNames.historyItems) i ON i.id = v.site_id
                WHERE i.is_deleted = 0 \(filter)
                ORDER BY v.date DESC
                LIMIT \(max(limit, 1))
                """
        }
        return db.runQuery(sql, args: filtered ? ["%\(trimmed)%"] : []) { row in
            HistoryEntry(id: row.int64(0),
                         siteID: row.int64(1),
                         url: row.url(2) ?? URL(string: "about:blank")!,
                         title: row.string(3),
                         date: row.date(4),
                         visitCount: row.int(5))
        }
    }

    /// Frecency-ranked matches for a typed string — the query an address bar
    /// wants. Not wired to any UI yet.
    func matches(for text: String, limit: Int = 8) -> [HistoryEntry] {
        guard !text.isEmpty else { return [] }
        return db.runQuery("""
            SELECT id, url, title, last_visit_date, visit_count FROM \(TableNames.historyItems)
            WHERE is_deleted = 0 AND (url LIKE ?1 OR title LIKE ?1)
            ORDER BY frecency DESC LIMIT ?2
            """, args: ["%\(text)%", limit]) { row in
            HistoryEntry(id: row.int64(0),
                         siteID: row.int64(0),
                         url: row.url(1) ?? URL(string: "about:blank")!,
                         title: row.string(2),
                         date: row.date(3),
                         visitCount: row.int(4))
        }
    }

    // MARK: - Deleting

    /// Remove one visit. When it was the last visit to that URL the page row goes
    /// too, so nothing is left to rank or autocomplete.
    func remove(_ entry: HistoryEntry) {
        db.run({ [weak self] connection in
            connection.executeChange("DELETE FROM \(TableNames.historyVisits) WHERE id = ?",
                                     args: [entry.id])
            self?.reconcile(siteID: entry.siteID, in: connection)
        }, then: { [weak self] in
            self?.notifyChange()
        })
    }

    /// Forget the page entirely — every visit to that URL, and the page row.
    func forget(_ entry: HistoryEntry) {
        db.run({ connection in
            connection.executeChange("DELETE FROM \(TableNames.historyItems) WHERE id = ?",
                                     args: [entry.siteID])
        }, then: { [weak self] in
            self?.notifyChange()
        })
    }

    func clear() {
        db.run({ [weak self] connection in
            connection.executeChange("DELETE FROM \(TableNames.historyVisits)")
            connection.executeChange("DELETE FROM \(TableNames.historyItems)")
            // Reclaim the pages so cleared URLs aren't still sitting in the file.
            connection.executeChange("VACUUM")
            self?.lastVisitID = nil
        }, then: { [weak self] in
            self?.notifyChange()
        })
    }

    /// Drop visits past the retention window, then any page left with none.
    func expireOldVisits() {
        let cutoff = Date().timeIntervalSince1970 - retention
        db.run { connection in
            connection.executeChange("DELETE FROM \(TableNames.historyVisits) WHERE date < ?",
                                     args: [cutoff])
            connection.executeChange("""
                DELETE FROM \(TableNames.historyItems)
                WHERE id NOT IN (SELECT DISTINCT site_id FROM \(TableNames.historyVisits))
                """)
        }
    }

    // MARK: - Migration from the flat JSON store

    /// Import the JSON history written before this database existed. It kept only
    /// the most recent visit per URL, so each row becomes a single visit.
    func importLegacy(_ rows: [(url: URL, title: String, date: Date)]) {
        guard !rows.isEmpty else { return }
        db.run({ [weak self] connection in
            guard let self else { return }
            connection.transaction { db in
                for row in rows {
                    let stamp = row.date.timeIntervalSince1970
                    db.executeChange("""
                        INSERT INTO \(TableNames.historyItems)
                            (guid, url, title, host, visit_count, last_visit_date, local_modified)
                        VALUES (?, ?, ?, ?, 1, ?, ?)
                        ON CONFLICT(url) DO UPDATE SET
                            visit_count     = visit_count + 1,
                            last_visit_date = MAX(\(TableNames.historyItems).last_visit_date,
                                                  excluded.last_visit_date)
                        """, args: [UUID().uuidString, row.url.absoluteString, row.title,
                                    row.url.host ?? "", stamp, stamp])
                    guard let siteID = self.siteID(for: row.url, in: db) else { continue }
                    db.executeChange("""
                        INSERT INTO \(TableNames.historyVisits) (site_id, date, type, is_local)
                        VALUES (?, ?, ?, 1)
                        """, args: [siteID, stamp, VisitTransition.link.rawValue])
                }
                return true
            }
            print("[History] imported \(rows.count) entries from the old JSON store")
        }, then: { [weak self] in
            self?.notifyChange()
        })
    }

    // MARK: - Internals (database queue only)

    private func siteID(for url: URL, in db: SQLiteConnection) -> Int64? {
        db.executeQuery("SELECT id FROM \(TableNames.historyItems) WHERE url = ?",
                        args: [url.absoluteString]) { $0.int64(0) }.first
    }

    /// Firefox's frecency, simplified: sum the weights of the ten most recent
    /// visits, each discounted by age. A page visited twice today outranks one
    /// visited ten times last year.
    private func updateFrecency(siteID: Int64, in db: SQLiteConnection) {
        let now = Date().timeIntervalSince1970
        let visits = db.executeQuery("""
            SELECT date, type FROM \(TableNames.historyVisits)
            WHERE site_id = ? ORDER BY date DESC LIMIT 10
            """, args: [siteID]) { ($0.double(0), $0.int(1)) }

        var score = 0.0
        for (date, rawType) in visits {
            let transition = VisitTransition(rawValue: rawType) ?? .link
            let ageDays = max(0, (now - date) / 86400)
            let recency: Double
            switch ageDays {
            case ..<4:   recency = 1.0
            case ..<14:  recency = 0.7
            case ..<31:  recency = 0.5
            case ..<90:  recency = 0.3
            default:     recency = 0.1
            }
            score += transition.weight * recency
        }
        db.executeChange("UPDATE \(TableNames.historyItems) SET frecency = ? WHERE id = ?",
                         args: [score, siteID])
    }

    /// Bring a page's counters back in line with its visits, dropping it when the
    /// last one is gone.
    private func reconcile(siteID: Int64, in db: SQLiteConnection) {
        let stats = db.executeQuery("""
            SELECT COUNT(*), COALESCE(MAX(date), 0) FROM \(TableNames.historyVisits)
            WHERE site_id = ?
            """, args: [siteID]) { ($0.int(0), $0.double(1)) }.first

        guard let (count, last) = stats else { return }
        guard count > 0 else {
            db.executeChange("DELETE FROM \(TableNames.historyItems) WHERE id = ?", args: [siteID])
            return
        }
        db.executeChange("""
            UPDATE \(TableNames.historyItems) SET visit_count = ?, last_visit_date = ? WHERE id = ?
            """, args: [count, last, siteID])
        updateFrecency(siteID: siteID, in: db)
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
