import Foundation

/// Table names, kept in one place so queries and migrations can't drift apart.
enum TableNames {
    static let historyItems = "history_items"
    static let historyVisits = "history_visits"
    /// The first cut of this database used `places`/`visits`. Version 2 renames
    /// them; these constants exist only so the migration can find them.
    static let legacyPlaces = "places"
    static let legacyVisits = "visits"
}

/// The browser's relational schema: unique pages in `history_items`, an
/// append-only row per visit in `history_visits`. Raw SQL on purpose — it keeps
/// the schema readable, portable, and identical to what the queries expect.
struct BrowserSchema: Schema {

    let name = "browser"
    let version: Int32 = 2

    // MARK: - DDL

    /// One row per unique URL.
    /// - `visit_count` / `typed_count` feed ranking.
    /// - `frecency` is the recency-weighted score the address bar sorts on.
    /// - `guid` / `is_deleted` / `local_modified` are the columns sync needs;
    ///   nothing writes to them yet, but adding columns later is the expensive
    ///   migration, so they're here from the start.
    let createHistoryItems = """
        CREATE TABLE IF NOT EXISTS \(TableNames.historyItems) (
            id              INTEGER PRIMARY KEY,
            guid            TEXT    NOT NULL UNIQUE,
            url             TEXT    NOT NULL UNIQUE,
            title           TEXT    NOT NULL DEFAULT '',
            host            TEXT    NOT NULL DEFAULT '',
            visit_count     INTEGER NOT NULL DEFAULT 0,
            typed_count     INTEGER NOT NULL DEFAULT 0,
            last_visit_date REAL    NOT NULL DEFAULT 0,
            frecency        REAL    NOT NULL DEFAULT 0,
            is_deleted      INTEGER NOT NULL DEFAULT 0,
            local_modified  REAL    NOT NULL DEFAULT 0
        )
        """

    /// One row per visit. `from_visit` chains a visit to the one that caused it,
    /// so a redirect or link chain stays reconstructable. `ON DELETE CASCADE`
    /// means forgetting a page can't leave orphaned visits behind.
    let createHistoryVisits = """
        CREATE TABLE IF NOT EXISTS \(TableNames.historyVisits) (
            id         INTEGER PRIMARY KEY,
            site_id    INTEGER NOT NULL REFERENCES \(TableNames.historyItems)(id) ON DELETE CASCADE,
            date       REAL    NOT NULL,
            type       INTEGER NOT NULL,
            from_visit INTEGER,
            is_local   INTEGER NOT NULL DEFAULT 1
        )
        """

    let createIndexes = [
        "CREATE INDEX IF NOT EXISTS idx_history_items_last_visit ON \(TableNames.historyItems)(last_visit_date DESC)",
        "CREATE INDEX IF NOT EXISTS idx_history_items_frecency   ON \(TableNames.historyItems)(frecency DESC)",
        "CREATE INDEX IF NOT EXISTS idx_history_items_host       ON \(TableNames.historyItems)(host)",
        "CREATE INDEX IF NOT EXISTS idx_history_visits_site      ON \(TableNames.historyVisits)(site_id)",
        "CREATE INDEX IF NOT EXISTS idx_history_visits_date      ON \(TableNames.historyVisits)(date DESC)",
    ]

    // MARK: - Schema lifecycle

    func create(_ db: SQLiteConnection) -> Bool {
        var ok = db.executeChange(createHistoryItems)
        ok = db.executeChange(createHistoryVisits) && ok
        for index in createIndexes {
            ok = db.executeChange(index) && ok
        }
        return ok
    }

    func update(_ db: SQLiteConnection, from: Int32) -> Bool {
        var ok = true
        if from < 2 {
            ok = migrateToV2(db)
        }
        return ok
    }

    /// v1 → v2: `places`/`visits` become `history_items`/`history_visits`, and the
    /// sync columns arrive. Done as create-copy-drop rather than ALTER TABLE so
    /// the result is identical to a table built fresh, whatever SQLite version
    /// the device shipped with.
    private func migrateToV2(_ db: SQLiteConnection) -> Bool {
        guard db.tableExists(TableNames.legacyPlaces) else {
            // No old data — the tables just need to exist.
            return create(db)
        }

        var ok = db.executeChange(createHistoryItems)
        ok = db.executeChange(createHistoryVisits) && ok
        guard ok else { return false }

        // hex(randomblob(16)) gives every migrated row the GUID sync will need.
        ok = db.executeChange("""
            INSERT OR IGNORE INTO \(TableNames.historyItems)
                (id, guid, url, title, host, visit_count, typed_count, last_visit_date, frecency)
            SELECT id, lower(hex(randomblob(16))), url, title, host,
                   visit_count, typed_count, last_visit_date, frecency
            FROM \(TableNames.legacyPlaces)
            """)

        if db.tableExists(TableNames.legacyVisits) {
            ok = db.executeChange("""
                INSERT OR IGNORE INTO \(TableNames.historyVisits)
                    (id, site_id, date, type, from_visit, is_local)
                SELECT id, place_id, visit_date, transition, from_visit, 1
                FROM \(TableNames.legacyVisits)
                """) && ok
        }

        ok = db.executeChange("DROP TABLE IF EXISTS \(TableNames.legacyVisits)") && ok
        ok = db.executeChange("DROP TABLE IF EXISTS \(TableNames.legacyPlaces)") && ok

        for index in createIndexes {
            ok = db.executeChange(index) && ok
        }
        print("[BrowserSchema] migrated v1 places/visits to v2 history_items/history_visits")
        return ok
    }
}
