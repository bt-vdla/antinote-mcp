import AppKit
import Foundation

struct WriteError: Error, CustomStringConvertible { let description: String }

/// Dispatches Antinote's documented x-callback URL actions without bringing Antinote to the front.
enum AntinoteURL {
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    static let maxEncodedLength = 30_000

    static func build(_ action: String, _ params: [(String, String)] = []) -> String {
        var s = "antinote://x-callback-url/\(action)"
        if !params.isEmpty {
            s += "?" + params.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: unreserved)!)" }.joined(separator: "&")
        }
        return s
    }

    static func open(_ action: String, _ params: [(String, String)] = []) throws {
        let s = build(action, params)
        guard s.count <= maxEncodedLength else { throw WriteError(description: "Note too large for Antinote's URL interface (~30 KB encoded).") }
        guard let url = URL(string: s) else { throw WriteError(description: "Could not build Antinote URL.") }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        NSWorkspace.shared.open(url, configuration: config) { _, err in failure = err; done.signal() }
        guard done.wait(timeout: .now() + 10) == .success else { throw WriteError(description: "Antinote did not accept the URL in time.") }
        if failure != nil { throw WriteError(description: "macOS could not hand the URL to Antinote. Is Antinote installed and running?") }
    }
}

/// Append-only local journal of every write, used by undo_last_edit.
final class Journal {
    let url: URL
    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("antinote-mcp")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("journal.jsonl")
    }

    func append(_ entry: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: entry), let line = String(data: data, encoding: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data((line + "\n").utf8)); try? h.close()
        } else {
            try? Data((line + "\n").utf8).write(to: url)
        }
    }

    func entries() -> [[String: Any]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }
}

enum Tombstone {
    static let marker = "🗑️ SAFE TO DELETE"
    static let rule = "────────"
    static let dateFormat: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "d MMM yyyy"; return f
    }()

    static func wrap(_ original: String, mergedInto target: Note?, reason: String?) -> String {
        var why: String
        if let t = target {
            let title = t.firstLine.replacingOccurrences(of: "*", with: "")
            why = "merged into “\(String(title.prefix(50)))” (id \(t.shortId))"
        } else {
            why = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "no longer needed"
        }
        if target != nil, let r = reason, !r.isEmpty { why += " — \(r)" }
        return "\(marker) — \(why) · \(dateFormat.string(from: Date()))\n\(rule)\n\(original)"
    }
}

/// Performs every content change through Antinote itself: promoteAndOpen(noteId) then overwriteCurrent.
/// Afterwards it re-reads the database to confirm the right note changed, and repairs any note that
/// was overwritten by mistake (e.g. if the current note switched underneath us).
final class SafeWriter {
    let store: Store
    let journal = Journal()
    init(store: Store) { self.store = store }

    static func same(_ a: String, _ b: String) -> Bool {
        a == b || a.trimmingCharacters(in: .whitespacesAndNewlines) == b.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func guardWritable(_ n: Note) throws {
        if n.trashed { throw WriteError(description: "Note \(n.shortId) is in the trash. Restore it in Antinote first.") }
        if n.locked || n.isPrivate { throw WriteError(description: "Note \(n.shortId) is locked/private; refusing to edit it.") }
        if n.archived { throw WriteError(description: "Note \(n.shortId) is archived. Editing archived notes isn't supported yet — unarchive it in Antinote first.") }
        if n.slotted { throw WriteError(description: "Note \(n.shortId) is in slot \(n.slotIndex). Antinote can't open slotted notes by id, so editing them isn't supported yet.") }
    }

    /// Replace a note's whole content. Returns the confirmed note.
    @discardableResult
    func replace(noteRef: String, expectedVersion: Int64?, newContent: String, action: String, repairing: Bool = false) throws -> Note {
        let before = try store.allNotes()
        let target = try store.resolve(noteRef, in: before)
        if !repairing {
            try guardWritable(target)
            if let v = expectedVersion, v != target.version {
                throw WriteError(description: "Note \(target.shortId) changed since you read it (version \(v) → \(target.version)). Call get_note again and redo the edit.")
            }
        }
        if target.content == newContent { return target }
        guard !newContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WriteError(description: "Refusing to blank a note. Use tombstone_note to mark it for deletion instead.")
        }

        journal.append(["ts": ISO.string(Date()), "action": action, "id": target.id,
                        "before": target.content, "after": newContent, "before_version": target.version])

        try AntinoteURL.open("promoteAndOpen", [("noteId", target.id)])
        Thread.sleep(forTimeInterval: 1.2)
        try AntinoteURL.open("overwriteCurrent", [("content", newContent)])

        let baseline = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0.content) })
        let deadline = Date().addingTimeInterval(6)
        var confirmed: Note?
        var wrong: [Note] = []
        repeat {
            Thread.sleep(forTimeInterval: 0.4)
            let now = try store.allNotes()
            confirmed = now.first { $0.id == target.id && SafeWriter.same($0.content, newContent) }
            wrong = now.filter { $0.id != target.id && baseline[$0.id] != nil && baseline[$0.id] != $0.content && SafeWriter.same($0.content, newContent) }
        } while confirmed == nil && wrong.isEmpty && Date() < deadline

        if !wrong.isEmpty {
            var repaired: [String] = []
            if !repairing {
                for w in wrong {
                    if let orig = baseline[w.id], (try? replace(noteRef: w.id, expectedVersion: nil, newContent: orig, action: "auto-repair", repairing: true)) != nil {
                        repaired.append(w.shortId)
                    }
                }
            }
            throw WriteError(description: "Antinote applied the edit to the wrong note (\(wrong.map(\.shortId).joined(separator: ", "))). "
                + (repaired.isEmpty ? "Automatic repair failed — check the journal and Antinote's backups." : "That note was restored to its previous text.")
                + " Note \(target.shortId) was not changed. Make sure no other Antinote window is mid-edit and retry.")
        }
        guard let ok = confirmed else {
            throw WriteError(description: "Antinote did not confirm the edit to \(target.shortId) within 6 s. Re-read the note before retrying.")
        }
        return ok
    }

    /// Create a note via createNote and return it once it appears in the database.
    func create(content: String) throws -> Note {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WriteError(description: "Content must not be blank.") }
        let before = try store.allNotes()
        let baseline = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0.content) })
        try AntinoteURL.open("createNote", [("content", content)])
        let deadline = Date().addingTimeInterval(6)
        repeat {
            Thread.sleep(forTimeInterval: 0.4)
            let now = try store.allNotes()
            if let n = now.first(where: { SafeWriter.same($0.content, content) && baseline[$0.id] != $0.content }) {
                journal.append(["ts": ISO.string(Date()), "action": "create", "id": n.id, "before": baseline[n.id] ?? "", "after": n.content])
                return n
            }
        } while Date() < deadline
        throw WriteError(description: "Antinote did not confirm the new note within 6 s.")
    }
}

/// Minimal line diff (LCS) for previews and results.
enum Diff {
    static func lines(_ old: String, _ new: String, context: Int = 2) -> String {
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        let n = a.count, m = b.count
        if n * m > 4_000_000 { return "(diff too large to show)" }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var ops: [(Character, String)] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] { ops.append((" ", a[i])); i += 1; j += 1 }
            else if j < m, i == n || dp[i][j + 1] >= dp[i + 1][j] { ops.append(("+", b[j])); j += 1 }
            else { ops.append(("-", a[i])); i += 1 }
        }
        let changed = ops.indices.filter { ops[$0].0 != " " }
        if changed.isEmpty { return "(no changes)" }
        var keep = Set<Int>()
        for c in changed { for k in max(0, c - context)...min(ops.count - 1, c + context) { keep.insert(k) } }
        var out: [String] = []
        var last = -1
        for k in keep.sorted() {
            if last >= 0 && k != last + 1 { out.append("…") }
            out.append("\(ops[k].0) \(ops[k].1)")
            last = k
        }
        return out.joined(separator: "\n")
    }
}
