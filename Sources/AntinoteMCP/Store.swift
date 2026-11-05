import Foundation
import SQLite3

/// One row of Antinote's Core Data `ZNOTE` table.
struct Note {
    let pk: Int64
    let id: String          // dashed, uppercase UUID (the format `promoteAndOpen` accepts)
    let content: String
    let version: Int64      // Core Data Z_OPT; bumps on every save
    let dbIndex: Int64      // list order (higher = nearer the top)
    let archived: Bool
    let trashed: Bool
    let locked: Bool
    let isPrivate: Bool
    let slotted: Bool
    let slotIndex: Int64
    let created: Date?
    let modified: Date?

    var shortId: String { String(id.prefix(8)).lowercased() }
    var firstLine: String {
        let line = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return line.trimmingCharacters(in: .whitespaces)
    }
    var isTombstone: Bool { content.hasPrefix(Tombstone.marker) }
    var state: String { trashed ? "trashed" : archived ? "archived" : "active" }

    func summary(preview: Int = 80) -> [String: Any] {
        var d: [String: Any] = [
            "id": id, "short_id": shortId, "version": version, "state": state,
            "first_line": String(firstLine.prefix(preview)),
            "length": content.count,
        ]
        if let m = modified { d["modified"] = ISO.string(m) }
        if slotted { d["slot"] = slotIndex }
        if locked { d["locked"] = true }
        if isPrivate { d["private"] = true }
        if isTombstone { d["tombstone"] = true }
        return d
    }

    func full() -> [String: Any] {
        var d = summary(preview: 200)
        d["content"] = content
        if let c = created { d["created"] = ISO.string(c) }
        return d
    }
}

enum ISO {
    static let f: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.timeZone = .current; return f }()
    static func string(_ d: Date) -> String { f.string(from: d) }
}

struct StoreError: Error, CustomStringConvertible { let description: String }

/// Read-only access to `cd-v1-notes.sqlite`. Every call opens a fresh read-only
/// connection so it always sees what Antinote last committed (including WAL data).
final class Store {
    static let dbName = "cd-v1-notes.sqlite"
    /// Returns the granted folder, re-requesting permission if it was lost.
    private let folder: () throws -> URL

    init(folder: @escaping () throws -> URL) { self.folder = folder }

    private func withDB<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        let path = try folder().appendingPathComponent(Store.dbName).path
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close(handle) }
            throw StoreError(description: "Cannot open Antinote's database read-only. Run `antinote-mcp grant` again.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        return try body(db)
    }

    func schemaCheck() throws -> [String] {
        try withDB { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(ZNOTE)", -1, &stmt, nil) == SQLITE_OK else {
                throw StoreError(description: "ZNOTE table not found — unsupported Antinote version.")
            }
            defer { sqlite3_finalize(stmt) }
            var cols: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW { cols.append(String(cString: sqlite3_column_text(stmt, 1))) }
            let needed = ["ZID", "ZCONTENT", "Z_OPT", "ZDBINDEX", "ZISARCHIVED", "ZSOFTDELETED", "ZLASTMODIFIED"]
            let missing = needed.filter { !cols.contains($0) }
            guard missing.isEmpty else { throw StoreError(description: "Unsupported schema; missing columns: \(missing)") }
            return cols
        }
    }

    func allNotes() throws -> [Note] {
        try withDB { db in
            let sql = """
            SELECT Z_PK, hex(ZID), ZCONTENT, Z_OPT, ZDBINDEX, ZISARCHIVED, ZSOFTDELETED, ZISLOCKED, ZISPRIVATE,
                   ZISSLOTTED, ZSLOTINDEX, ZCREATED, ZLASTMODIFIED
            FROM ZNOTE WHERE ZID IS NOT NULL
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StoreError(description: "Query failed: " + String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            var out: [Note] = []
            func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
            func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
            func date(_ i: Int32) -> Date? {
                sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, i))
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(Note(pk: int(0), id: Store.dashed(text(1)), content: text(2), version: int(3), dbIndex: int(4),
                                archived: int(5) != 0, trashed: int(6) != 0, locked: int(7) != 0, isPrivate: int(8) != 0,
                                slotted: int(9) != 0, slotIndex: int(10), created: date(11), modified: date(12)))
            }
            return out
        }
    }

    static func dashed(_ hex: String) -> String {
        let h = Array(hex.uppercased())
        guard h.count == 32 else { return hex.uppercased() }
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(h[$0]) }.joined(separator: "-")
    }

    /// Accepts a full UUID (with or without dashes) or a unique prefix of at least 6 hex characters.
    func resolve(_ ref: String, in notes: [Note]? = nil) throws -> Note {
        let key = ref.replacingOccurrences(of: "-", with: "").uppercased().trimmingCharacters(in: .whitespaces)
        guard key.count >= 6, key.allSatisfy({ $0.isHexDigit }) else {
            throw StoreError(description: "Invalid note id '\(ref)'. Use the id or short_id from list_notes/search_notes.")
        }
        let all = try notes ?? allNotes()
        let hits = all.filter { $0.id.replacingOccurrences(of: "-", with: "").hasPrefix(key) }
        guard hits.count == 1 else {
            throw StoreError(description: hits.isEmpty ? "No note with id '\(ref)'." : "Id prefix '\(ref)' is ambiguous; use more characters.")
        }
        return hits[0]
    }
}

/// Antinote's list order: slotted notes first (by slot), then by ZDBINDEX descending.
func appOrder(_ a: Note, _ b: Note) -> Bool {
    if a.slotted != b.slotted { return a.slotted }
    if a.slotted { return a.slotIndex < b.slotIndex }
    return a.dbIndex > b.dbIndex
}
