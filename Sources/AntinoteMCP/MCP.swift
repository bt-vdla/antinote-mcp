import Foundation

/// A minimal, dependency-free MCP server over stdio (newline-delimited JSON-RPC 2.0).
/// Implements: initialize, ping, tools/list, tools/call, prompts/list, prompts/get.
final class MCPServer {
    static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    let tools: Tools
    let version: String

    init(tools: Tools, version: String) { self.tools = tools; self.version = version }

    func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]]); continue
            }
            handle(msg)
        }
    }

    private func handle(_ msg: [String: Any]) {
        guard let method = msg["method"] as? String else { return }  // responses from client: ignore
        let id = msg["id"]
        let params = msg["params"] as? [String: Any] ?? [:]
        guard id != nil else { return }  // notification (e.g. notifications/initialized)

        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            reply(id, ["protocolVersion": MCPServer.supportedVersions.contains(asked) ? asked : MCPServer.supportedVersions[0],
                       "capabilities": ["tools": ["listChanged": false], "prompts": ["listChanged": false]],
                       "serverInfo": ["name": "antinote-mcp", "version": version],
                       "instructions": Prompts.instructions])
        case "ping": reply(id, [:])
        case "tools/list": reply(id, ["tools": Tools.definitions])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let result = try tools.call(name, args)
                reply(id, ["content": [["type": "text", "text": json(result)]]])
            } catch {
                reply(id, ["content": [["type": "text", "text": "Error: \(error)"]], "isError": true])
            }
        case "prompts/list": reply(id, ["prompts": Prompts.list])
        case "prompts/get":
            if let p = Prompts.get(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:]) { reply(id, p) }
            else { fail(id, -32602, "Unknown prompt") }
        default: fail(id, -32601, "Method not found: \(method)")
        }
    }

    private func reply(_ id: Any?, _ result: [String: Any]) { send(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]) }
    private func fail(_ id: Any?, _ code: Int, _ message: String) {
        send(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }
    private func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
    private func json(_ v: Any) -> String {
        guard JSONSerialization.isValidJSONObject(v),
              let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "\(v)" }
        return String(decoding: d, as: UTF8.self)
    }
}

/// Server instructions and reusable prompts.
enum Prompts {
    static let instructions = """
    Antinote notes have no titles; the first line acts as one. Read with list_notes/search_notes/get_note. \
    Every write goes through Antinote itself and is verified; each edited note moves to the top of the user's list. \
    Prefer edit_note with exact `edits` over full rewrites, and keep checklist ticks (` /x` at line end). \
    Notes can't be deleted or archived from here: when a note is superseded (merged, split, replaced), mark it with \
    tombstone_note (or use merge_notes, which does this in the safe order). Locked, private, archived, slotted and trashed notes are read-only. \
    Show the user a dry_run diff before large or multi-note changes.
    """

    static let list: [[String: Any]] = [
        ["name": "weekly_digest", "description": "Summarise notes changed in the last N days into one digest note.",
         "arguments": [["name": "days", "description": "Look-back window in days (default 7)", "required": false]]],
        ["name": "collect_todos", "description": "Gather open to-dos scattered across notes into one checklist note.", "arguments": []],
        ["name": "find_duplicates", "description": "Find overlapping notes and propose merges (dry run first).", "arguments": []],
        ["name": "tidy_note", "description": "Clean up one messy note's structure without losing content.",
         "arguments": [["name": "id", "description": "Note id or short_id", "required": true]]],
    ]

    static func get(_ name: String, _ args: [String: Any]) -> [String: Any]? {
        let text: String
        switch name {
        case "weekly_digest":
            let days = (args["days"] as? String) ?? "7"
            text = "Using the Antinote tools, list notes modified in the last \(days) days, read them, and draft a digest grouped by topic with open items called out. Show me the draft; create it as a new note only after I approve."
        case "collect_todos":
            text = "Search my active Antinote notes for open to-dos (unchecked list items, TODO, action items, 'need to', 'follow up'). Draft one checklist note starting with `list` grouped by source note (first line + short_id). Show it to me before creating it. Don't modify the source notes."
        case "find_duplicates":
            text = "Scan my active Antinote notes for notes covering the same topic. For each group, propose a merged text and call merge_notes with dry_run=true to show the diff. Only run the real merge for groups I approve."
        case "tidy_note":
            let id = (args["id"] as? String) ?? ""
            text = "Read Antinote note \(id) with get_note. Propose a cleaner structure (headings, bullets, fixed typos) that keeps every fact and every ` /x` tick. Show a dry_run diff via edit_note, and apply only after I approve."
        default: return nil
        }
        return ["description": name, "messages": [["role": "user", "content": ["type": "text", "text": text]]]]
    }
}
