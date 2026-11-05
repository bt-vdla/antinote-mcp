import Foundation

struct ToolError: Error, CustomStringConvertible { let description: String }

/// Tool definitions (MCP `tools/list`) and handlers (`tools/call`).
final class Tools {
    let store: Store
    let writer: SafeWriter
    init(store: Store) { self.store = store; writer = SafeWriter(store: store) }

    // MARK: - Schema helpers
    private static func obj(_ props: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": props, "required": required, "additionalProperties": false]
    }
    private static func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
    private static func int(_ d: String) -> [String: Any] { ["type": "integer", "description": d] }
    private static func bool(_ d: String) -> [String: Any] { ["type": "boolean", "description": d] }
    private static let idDesc = "Note id or short_id (first 8 hex chars) from list_notes/search_notes."
    private static let versionDesc = "The note's `version` from your most recent get_note. The edit is refused if the note changed since."

    private static func tool(_ name: String, _ desc: String, _ schema: [String: Any], readOnly: Bool, destructive: Bool = false) -> [String: Any] {
        ["name": name, "description": desc, "inputSchema": schema,
         "annotations": ["readOnlyHint": readOnly, "destructiveHint": destructive, "openWorldHint": false]]
    }

    static let definitions: [[String: Any]] = [
        tool("antinote_status", "Check database access and schema, and show note counts. Returns no note text.", obj([:]), readOnly: true),
        tool("list_notes", "List notes in Antinote's own order (slots first, then most recently promoted). Notes have no titles; `first_line` stands in for one.",
             obj(["state": ["type": "string", "enum": ["active", "archived", "trashed", "all"], "description": "Default active."],
                  "limit": int("Default 30, max 200."), "offset": int("Default 0."),
                  "include_tombstones": bool("Include notes marked SAFE TO DELETE. Default true.")]), readOnly: true),
        tool("search_notes", "Case-insensitive text search across notes. Returns matching notes with up to 3 matching lines each.",
             obj(["query": str("Text to find."), "state": ["type": "string", "enum": ["active", "archived", "trashed", "all"], "description": "Default active."],
                  "limit": int("Default 20."), "include_tombstones": bool("Default false.")], required: ["query"]), readOnly: true),
        tool("get_note", "Read a note's full text plus its `version` (needed for any edit).",
             obj(["id": str(idDesc)], required: ["id"]), readOnly: true),
        tool("create_note", "Create a new note (through Antinote itself). Returns the new note's id.",
             obj(["content": str("Full text. The first line acts as the title.")], required: ["content"]), readOnly: false),
        tool("edit_note", """
             Edit a note in place, through Antinote itself, then confirm by re-reading. Provide exactly one of: `edits` (preferred — exact find/replace, \
             keeps everything else byte-for-byte), `append`, `prepend`, or `content` (full rewrite). Checklist ticks are the text ` /x` at the end of a line — keep them. \
             Side effect: the note moves to the top of Antinote's list. Use dry_run to preview the diff first.
             """,
             obj(["id": str(idDesc), "expected_version": int(versionDesc),
                  "edits": ["type": "array", "description": "Exact find/replace operations applied in order.",
                            "items": obj(["find": str("Exact text to find (must occur exactly once unless replace_all)."),
                                          "replace": str("Replacement text."), "replace_all": bool("Replace every occurrence.")],
                                         required: ["find", "replace"])],
                  "append": str("Text to add as new line(s) at the end."), "prepend": str("Text to add as new line(s) at the top."),
                  "content": str("Complete new text (full rewrite)."), "dry_run": bool("Only return the diff; change nothing.")],
                 required: ["id", "expected_version"]), readOnly: false, destructive: true),
        tool("tombstone_note", """
             Mark a note as safe to delete (Antinote's URL interface cannot delete or archive). Adds a header line \
             `🗑️ SAFE TO DELETE — merged into “…” (id …) · date` above the untouched original text, so nothing is lost until the user deletes it.
             """,
             obj(["id": str(idDesc), "expected_version": int(versionDesc),
                  "merged_into": str("Id of the note that now holds this content (optional)."),
                  "reason": str("Why it's no longer needed, if not merged (or extra context)."), "dry_run": bool("Preview only.")],
                 required: ["id", "expected_version"]), readOnly: false),
        tool("merge_notes", """
             Merge several notes safely: first writes `merged_content` into the target (an existing note, or a new one if target_id is omitted) and \
             confirms it, and only then tombstones each source note pointing at the target. You must have read every note involved: pass each one's \
             version in `expected_versions`. Write merged_content yourself so it contains everything worth keeping from the sources.
             """,
             obj(["source_ids": ["type": "array", "items": ["type": "string"], "description": "Notes being merged (ids or short_ids)."],
                  "target_id": str("Existing note to receive the merged text. Omit to create a new note."),
                  "merged_content": str("The complete text of the merged note."),
                  "expected_versions": ["type": "object", "additionalProperties": ["type": "integer"],
                                        "description": "Map of id/short_id → version for every source and the target."],
                  "dry_run": bool("Preview only.")],
                 required: ["source_ids", "merged_content", "expected_versions"]), readOnly: false, destructive: true),
        tool("list_tombstones", "List notes marked SAFE TO DELETE, as a cleanup checklist for the user.", obj([:]), readOnly: true),
        tool("undo_last_edit", "Restore the text a note had before its most recent edit by this server (only if nobody changed it since).",
             obj(["id": str("Note to undo. Omit for the most recent edit overall.")]), readOnly: false),
    ]

    // MARK: - Dispatch
    func call(_ name: String, _ a: [String: Any]) throws -> Any {
        switch name {
        case "antinote_status": return try status()
        case "list_notes": return try list(a)
        case "search_notes": return try search(a)
        case "get_note": return try store.resolve(try req(a, "id")).full()
        case "create_note":
            let n = try writer.create(content: try req(a, "content"))
            return ["created": n.summary()]
        case "edit_note": return try edit(a)
        case "tombstone_note": return try tombstone(a)
        case "merge_notes": return try merge(a)
        case "list_tombstones":
            let t = try store.allNotes().filter { $0.isTombstone && !$0.trashed }.sorted(by: appOrder)
            return ["count": t.count, "tombstones": t.map { n -> [String: Any] in var d = n.summary(preview: 160); d["header"] = n.firstLine; return d },
                    "hint": "Delete these in Antinote when you're happy. Search for “SAFE TO DELETE” to find them."]
        case "undo_last_edit": return try undo(a)
        default: throw ToolError(description: "Unknown tool \(name)")
        }
    }

    private func req(_ a: [String: Any], _ k: String) throws -> String {
        guard let v = a[k] as? String, !v.isEmpty else { throw ToolError(description: "Missing `\(k)`.") }
        return v
    }
    private func intArg(_ a: [String: Any], _ k: String) -> Int64? {
        if let i = a[k] as? Int { return Int64(i) }
        if let d = a[k] as? Double { return Int64(d) }
        if let s = a[k] as? String { return Int64(s) }
        return nil
    }

    private func filtered(_ notes: [Note], state: String) -> [Note] {
        switch state {
        case "all": return notes
        case "archived": return notes.filter { $0.archived && !$0.trashed }
        case "trashed": return notes.filter { $0.trashed }
        default: return notes.filter { !$0.archived && !$0.trashed }
        }
    }

    // MARK: - Handlers
    private func status() throws -> [String: Any] {
        _ = try store.schemaCheck()
        let n = try store.allNotes()
        return ["database": "readable", "schema": "core-data ZNOTE (supported)",
                "notes": ["active": n.filter { !$0.archived && !$0.trashed }.count, "archived": n.filter { $0.archived && !$0.trashed }.count,
                          "trashed": n.filter { $0.trashed }.count, "slotted": n.filter { $0.slotted }.count,
                          "tombstones": n.filter { $0.isTombstone && !$0.trashed }.count],
                "write_path": "Antinote URL actions (promoteAndOpen + overwriteCurrent), verified by re-reading",
                "journal": writer.journal.url.path]
    }

    private func list(_ a: [String: Any]) throws -> [String: Any] {
        var notes = filtered(try store.allNotes(), state: a["state"] as? String ?? "active").sorted(by: appOrder)
        if (a["include_tombstones"] as? Bool) == false { notes.removeAll { $0.isTombstone } }
        let limit = min(Int(intArg(a, "limit") ?? 30), 200), offset = Int(intArg(a, "offset") ?? 0)
        let page = notes.dropFirst(offset).prefix(limit)
        return ["total": notes.count, "offset": offset, "notes": page.map { $0.summary() }]
    }

    private func search(_ a: [String: Any]) throws -> [String: Any] {
        let q = try req(a, "query")
        var notes = filtered(try store.allNotes(), state: a["state"] as? String ?? "active").sorted(by: appOrder)
        if (a["include_tombstones"] as? Bool) != true { notes.removeAll { $0.isTombstone } }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let hits = notes.filter { $0.content.range(of: q, options: opts) != nil }
        let limit = Int(intArg(a, "limit") ?? 20)
        return ["query": q, "total": hits.count, "results": hits.prefix(limit).map { n -> [String: Any] in
            var d = n.summary()
            let lines = n.content.components(separatedBy: "\n").enumerated()
                .filter { $0.element.range(of: q, options: opts) != nil }.prefix(3)
                .map { "L\($0.offset + 1): \(String($0.element.prefix(200)))" }
            d["matches"] = Array(lines)
            return d
        }]
    }

    static func applyEdits(_ text: String, _ edits: [[String: Any]]) throws -> String {
        var out = text
        for (i, e) in edits.enumerated() {
            guard let find = e["find"] as? String, !find.isEmpty, let rep = e["replace"] as? String else {
                throw ToolError(description: "edits[\(i)] needs non-empty `find` and a `replace`.")
            }
            let count = out.components(separatedBy: find).count - 1
            if count == 0 { throw ToolError(description: "edits[\(i)]: `find` text not found. Re-read the note; text must match exactly (including /x ticks and spacing).") }
            if count > 1 && (e["replace_all"] as? Bool) != true {
                throw ToolError(description: "edits[\(i)]: `find` occurs \(count) times. Add surrounding text to make it unique, or set replace_all.")
            }
            out = out.replacingOccurrences(of: find, with: rep)
        }
        return out
    }

    private func edit(_ a: [String: Any]) throws -> [String: Any] {
        let note = try store.resolve(try req(a, "id"))
        guard let version = intArg(a, "expected_version") else { throw ToolError(description: "Missing `expected_version` — call get_note first.") }
        let modes = ["edits", "append", "prepend", "content"].filter { a[$0] != nil }
        guard modes.count == 1 else { throw ToolError(description: "Provide exactly one of edits, append, prepend, content.") }
        let new: String
        switch modes[0] {
        case "edits":
            guard let e = a["edits"] as? [[String: Any]], !e.isEmpty else { throw ToolError(description: "`edits` must be a non-empty array.") }
            new = try Tools.applyEdits(note.content, e)
        case "append":
            let t = try req(a, "append")
            new = note.content + (note.content.hasSuffix("\n") ? "" : "\n") + t
        case "prepend": new = try req(a, "prepend") + "\n" + note.content
        default: new = try req(a, "content")
        }
        let diff = Diff.lines(note.content, new)
        if (a["dry_run"] as? Bool) == true {
            try writer.guardWritable(note)
            if version != note.version { throw ToolError(description: "Version mismatch (\(version) vs \(note.version)); re-read the note.") }
            return ["dry_run": true, "id": note.id, "diff": diff]
        }
        let done = try writer.replace(noteRef: note.id, expectedVersion: version, newContent: new, action: "edit")
        return ["edited": done.summary(), "diff": diff, "note": "Confirmed in Antinote's database. The note moved to the top of the list."]
    }

    private func tombstone(_ a: [String: Any]) throws -> [String: Any] {
        let all = try store.allNotes()
        let note = try store.resolve(try req(a, "id"), in: all)
        guard let version = intArg(a, "expected_version") else { throw ToolError(description: "Missing `expected_version`.") }
        if note.isTombstone { return ["already_tombstoned": note.summary()] }
        var target: Note?
        if let t = a["merged_into"] as? String, !t.isEmpty {
            target = try store.resolve(t, in: all)
            if target?.id == note.id { throw ToolError(description: "A note can't be merged into itself.") }
        }
        let new = Tombstone.wrap(note.content, mergedInto: target, reason: a["reason"] as? String)
        if (a["dry_run"] as? Bool) == true { return ["dry_run": true, "header": new.components(separatedBy: "\n")[0]] }
        let done = try writer.replace(noteRef: note.id, expectedVersion: version, newContent: new, action: "tombstone")
        return ["tombstoned": done.summary()]
    }

    private func merge(_ a: [String: Any]) throws -> [String: Any] {
        guard let srcRefs = a["source_ids"] as? [String], !srcRefs.isEmpty else { throw ToolError(description: "`source_ids` must list at least one note.") }
        let merged = try req(a, "merged_content")
        guard let versionsRaw = a["expected_versions"] as? [String: Any] else { throw ToolError(description: "Missing `expected_versions`.") }
        let all = try store.allNotes()
        var versions: [String: Int64] = [:]
        for (k, v) in versionsRaw {
            let n = try store.resolve(k, in: all)
            guard let i = (v as? Int).map(Int64.init) ?? (v as? Double).map({ Int64($0) }) else { throw ToolError(description: "Version for \(k) must be an integer.") }
            versions[n.id] = i
        }
        let target = try (a["target_id"] as? String).map { try store.resolve($0, in: all) }
        let sources = try srcRefs.map { try store.resolve($0, in: all) }.filter { $0.id != target?.id }
        for n in sources + (target.map { [$0] } ?? []) {
            guard let v = versions[n.id] else { throw ToolError(description: "expected_versions is missing note \(n.shortId). Read every note before merging.") }
            if v != n.version { throw ToolError(description: "Note \(n.shortId) changed since you read it (\(v) → \(n.version)). Re-read and retry.") }
            try writer.guardWritable(n)
        }
        if (a["dry_run"] as? Bool) == true {
            return ["dry_run": true,
                    "target": target.map { ["id": $0.id, "diff": Diff.lines($0.content, merged)] as [String: Any] } ?? ["new_note": true],
                    "will_tombstone": sources.map { $0.summary() }]
        }
        // 1. Write the merged note and confirm it before touching any source.
        let dest: Note = try target.map { try writer.replace(noteRef: $0.id, expectedVersion: versions[$0.id], newContent: merged, action: "merge-target") }
            ?? writer.create(content: merged)
        // 2. Tombstone sources, one by one, reporting partial progress if anything fails.
        var done: [[String: Any]] = []
        for s in sources {
            do {
                let t = try writer.replace(noteRef: s.id, expectedVersion: versions[s.id],
                                           newContent: Tombstone.wrap(s.content, mergedInto: dest, reason: nil), action: "merge-tombstone")
                done.append(t.summary())
            } catch {
                return ["merged_into": dest.summary(), "tombstoned": done,
                        "error": "Stopped at \(s.shortId): \(error). The merged note is safe; the remaining sources were left untouched."]
            }
        }
        return ["merged_into": dest.summary(), "tombstoned": done]
    }

    private func undo(_ a: [String: Any]) throws -> [String: Any] {
        let all = try store.allNotes()
        let filterId = try (a["id"] as? String).map { try store.resolve($0, in: all).id }
        let entries = writer.journal.entries().reversed().filter { e in
            (e["action"] as? String) != "auto-repair" && (filterId == nil || (e["id"] as? String) == filterId)
        }
        guard let e = entries.first, let id = e["id"] as? String, let before = e["before"] as? String, let after = e["after"] as? String else {
            throw ToolError(description: "No edits by this server to undo\(filterId == nil ? "" : " for that note").")
        }
        let current = try store.resolve(id, in: all)
        guard SafeWriter.same(current.content, after) else {
            throw ToolError(description: "Note \(current.shortId) changed after that edit, so undo would overwrite newer text. Read it and edit manually. Previous text:\n\(before)")
        }
        if (e["action"] as? String) == "create" || before.isEmpty {
            throw ToolError(description: "That note was created by this server; there's no earlier text. Use tombstone_note to mark it for deletion.")
        }
        let restored = try writer.replace(noteRef: id, expectedVersion: current.version, newContent: before, action: "undo")
        return ["restored": restored.summary(), "diff": Diff.lines(after, before)]
    }
}
