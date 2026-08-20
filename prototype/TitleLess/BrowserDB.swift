import Foundation
import SQLite3

/// sqlite3 must copy bound bytes — Swift's temporaries don't outlive the call.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Row

/// A single result row. Columns are read by index, in the order the SELECT
/// listed them.
final class SQLiteRow {
    private let stmt: OpaquePointer

    fileprivate init(stmt: OpaquePointer) { self.stmt = stmt }

    func string(_ index: Int32) -> String {
        sqlite3_column_text(stmt, index).map { String(cString: $0) } ?? ""
    }
    func int64(_ index: Int32) -> Int64 { sqlite3_column_int64(stmt, index) }
    func int(_ index: Int32) -> Int { Int(sqlite3_column_int(stmt, index)) }
    func double(_ index: Int32) -> Double { sqlite3_column_double(stmt, index) }
    func date(_ index: Int32) -> Date { Date(timeIntervalSince1970: double(index)) }
    func url(_ index: Int32) -> URL? { URL(string: string(index)) }
    func isNull(_ index: Int32) -> Bool {
        sqlite3_column_type(stmt, index) == SQLITE_NULL
    }
}

// MARK: - Connection

/// Thin wrapper over one sqlite3 handle. Not thread-safe on its own — every
/// caller reaches it through `BrowserDB`'s serial queue.
final class SQLiteConnection {

    fileprivate var handle: OpaquePointer?

    /// Pass ":memory:" for a private/incognito profile — nothing touches disk.
    init?(path: String) {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            log("[BrowserDB] open failed: \(errorMessage)")
            return nil
        }
        // WAL lets the panel read while a navigation is still writing. An
        // in-memory database has no journal to configure.
        if path != ":memory:" {
            executeChange("PRAGMA journal_mode = WAL")
            executeChange("PRAGMA synchronous = NORMAL")
        }
        executeChange("PRAGMA foreign_keys = ON")
    }

    deinit { sqlite3_close(handle) }

    var errorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection"
    }

    var lastInsertedRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    var userVersion: Int32 {
        get { executeQuery("PRAGMA user_version") { Int32($0.int(0)) }.first ?? 0 }
        set { executeChange("PRAGMA user_version = \(newValue)") }
    }

    /// INSERT/UPDATE/DELETE/DDL. Returns false and logs on failure — a broken
    /// history write must never take the browser down.
    @discardableResult
    func executeChange(_ sql: String, args: [Any?] = []) -> Bool {
        guard let stmt = prepare(sql, args: args) else { return false }
        defer { sqlite3_finalize(stmt) }
        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            log("[BrowserDB] step failed (\(sql)): \(errorMessage)")
            return false
        }
        return true
    }

    /// SELECT. `factory` maps each row while the statement is still alive.
    func executeQuery<T>(_ sql: String, args: [Any?] = [], factory: (SQLiteRow) -> T) -> [T] {
        guard let stmt = prepare(sql, args: args) else { return [] }
        defer { sqlite3_finalize(stmt) }
        let row = SQLiteRow(stmt: stmt)
        var results: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(factory(row))
        }
        return results
    }

    /// Run a batch atomically. Returning false from `block` rolls it back.
    func transaction(_ block: (SQLiteConnection) -> Bool) {
        executeChange("BEGIN TRANSACTION")
        if block(self) {
            executeChange("COMMIT")
        } else {
            executeChange("ROLLBACK")
        }
    }

    func tableExists(_ name: String) -> Bool {
        !executeQuery("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
                      args: [name]) { $0.string(0) }.isEmpty
    }

    private func prepare(_ sql: String, args: [Any?]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            log("[BrowserDB] prepare failed (\(sql)): \(errorMessage)")
            return nil
        }
        for (offset, arg) in args.enumerated() {
            let index = Int32(offset + 1)
            switch arg {
            case nil:                sqlite3_bind_null(stmt, index)
            case let value as String: sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
            case let value as Int:    sqlite3_bind_int64(stmt, index, Int64(value))
            case let value as Int32:  sqlite3_bind_int(stmt, index, value)
            case let value as Int64:  sqlite3_bind_int64(stmt, index, value)
            case let value as Double: sqlite3_bind_double(stmt, index, value)
            case let value as Bool:   sqlite3_bind_int(stmt, index, value ? 1 : 0)
            case let value as Date:   sqlite3_bind_double(stmt, index, value.timeIntervalSince1970)
            default:
                log("[BrowserDB] unsupported bind type at \(index): \(String(describing: arg))")
                sqlite3_bind_null(stmt, index)
            }
        }
        return stmt
    }
}

// MARK: - Schema

/// A versioned set of tables. `BrowserDB` creates it on a fresh file and calls
/// `update` when the stored `user_version` is behind.
protocol Schema {
    var name: String { get }
    var version: Int32 { get }
    func create(_ db: SQLiteConnection) -> Bool
    func update(_ db: SQLiteConnection, from: Int32) -> Bool
}

// MARK: - Database

/// Owns the connection and the queue everything runs on.
///
/// Writes are async: a page commit must not make a swipe-navigation wait on the
/// disk. Reads are sync — callers need rows back — and every read the app makes
/// is index-backed and bounded by a LIMIT.
final class BrowserDB {

    private let connection: SQLiteConnection?
    private let queue: DispatchQueue

    /// - Parameter filename: a file name inside `directory`, or ":memory:" for a
    ///   private profile that must leave nothing behind.
    init(filename: String, schema: Schema, directory: URL) {
        let path: String
        if filename == ":memory:" {
            path = filename
        } else {
            try? FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)
            path = directory.appendingPathComponent(filename).path
        }
        queue = DispatchQueue(label: "browser.db.\(schema.name)")
        connection = SQLiteConnection(path: path)
        queue.sync { prepareSchema(schema) }
    }

    private func prepareSchema(_ schema: Schema) {
        guard let connection else { return }
        let current = connection.userVersion
        if current == 0 {
            guard schema.create(connection) else {
                log("[BrowserDB] schema create failed: \(connection.errorMessage)")
                return
            }
            connection.userVersion = schema.version
        } else if current < schema.version {
            guard schema.update(connection, from: current) else {
                log("[BrowserDB] schema update failed: \(connection.errorMessage)")
                return
            }
            connection.userVersion = schema.version
        }
    }

    // MARK: Access

    /// Background write. Fire-and-forget by design.
    func run(_ block: @escaping (SQLiteConnection) -> Void) {
        queue.async { [weak self] in
            guard let connection = self?.connection else { return }
            block(connection)
        }
    }

    /// Background write, with a callback once it has landed (used when the UI
    /// needs to repaint after the change).
    func run(_ block: @escaping (SQLiteConnection) -> Void, then completion: @escaping () -> Void) {
        queue.async { [weak self] in
            if let connection = self?.connection { block(connection) }
            DispatchQueue.main.async(execute: completion)
        }
    }

    /// Synchronous read. Safe from the main thread: serial queue, indexed
    /// queries, and writes ahead of it in the queue are small.
    func read<T>(_ block: (SQLiteConnection) -> T) -> T? {
        queue.sync { [weak self] in
            guard let connection = self?.connection else { return nil }
            return block(connection)
        }
    }

    func runQuery<T>(_ sql: String, args: [Any?] = [], factory: @escaping (SQLiteRow) -> T) -> [T] {
        read { $0.executeQuery(sql, args: args, factory: factory) } ?? []
    }
}
