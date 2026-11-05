# antinote-mcp

An MCP server that lets Claude **read, search, edit, merge and tidy your [Antinote](https://antinote.io) notes**, written in Swift. It also includes [`date_note`](extensions/date_note), an Antinote extension that opens a new note with today's date in bold at the top.

> **Built on top of [maferland/antinote-mcp](https://github.com/maferland/antinote-mcp).** maferland's server (TypeScript, MIT) worked out the read side first: decoding Antinote's Core Data schema, and using a sandboxed helper with a user-picked folder so no Full Disk Access is needed. It writes only through `createNote` and `appendToCurrent`. This project is a separate Swift implementation that adds what that server leaves out: **in-place edits of any note by id**, safe merges, "safe to delete" tombstones, an undo journal and dry-run diffs. It also documents what we learned testing Antinote's write paths. No code is copied from maferland's repo; the ideas and groundwork are theirs.

## What Claude can do with it

| Tool | What it does |
|---|---|
| `antinote_status` | Checks database access and the schema, and returns note counts (no note text) |
| `list_notes` | Notes in Antinote's own order (slots first). Filter by active, archived, trashed or all |
| `search_notes` | Case- and accent-insensitive text search, with the matching lines |
| `get_note` | Full text plus its `version` (needed for any edit) |
| `create_note` | Creates a note through Antinote and returns its id |
| `edit_note` | **Edits any note in place.** Takes exact find/replace `edits`, `append`, `prepend` or a full `content` rewrite. Supports `dry_run` diffs |
| `merge_notes` | Writes the merged text to a target (existing or new) and **confirms it first**, then tombstones each source |
| `tombstone_note` | Marks a note "🗑️ SAFE TO DELETE — merged into “…” (id …) · date", keeping the original text below |
| `list_tombstones` | Your cleanup checklist |
| `undo_last_edit` | Restores a note's text from before this server's last edit, if nothing changed since |

It also ships MCP prompts: `weekly_digest`, `collect_todos`, `find_duplicates` and `tidy_note`.

## How it works, and why this design

Antinote keeps notes in a Core Data SQLite database inside its sandbox, `cd-v1-notes.sqlite`, with one row per note in `ZNOTE`. Notes have no titles. We tested every write path against a live Antinote before writing this server:

| Approach | Result |
|---|---|
| **Direct SQLite writes** (even followed by Antinote's `reloadDB` action) | ❌ **Lost.** Antinote keeps notes in memory and **saves its old copy back** the next time you type in that note. Never write to the database directly. |
| `appendToCurrent` / `overwriteCurrent` on their own | ⚠️ They act on *whatever note is current*. `reloadDB` and other events can switch the current note without warning; one test append landed in a real note. |
| **`promoteAndOpen(noteId)` → `overwriteCurrent` → re-read and verify** | ✅ Reliable. Antinote does the write itself, so checklists, links and change tracking stay consistent. It runs in the background without stealing focus. |

So the server:

- **reads** the database directly, read-only, through a sandboxed security-scoped bookmark to the one folder you pick. No Full Disk Access is needed.
- **writes** only through Antinote's own URL actions: it opens the note by id, overwrites it, then re-reads the database until the change is confirmed.
- **checks** that no other note was changed. If one was (for example, the current note switched), it restores that note automatically and reports an error.
- **refuses** an edit if the note's `version` (Core Data `Z_OPT`) changed since Claude read it, so your own typing is never overwritten.
- **journals** every write (the text before and after) to `~/Library/Containers/io.github.bt-vdla.antinote-mcp/Data/Library/Application Support/antinote-mcp/journal.jsonl`.

### Things to know

- **Every edit moves that note to the top of Antinote's list** (that's what "promote" does). Archive order is unaffected.
- **No deleting or archiving.** Antinote's URL interface can't do it, and direct database writes don't stick. Superseded notes get a tombstone header instead, and you delete them yourself; search Antinote for `SAFE TO DELETE` to find them.
- **Checklist ticks are text.** A ticked item is the line text followed by ` /x`, and Antinote rebuilds its checklist rows from the note text on every save. Patch-style `edits` keep ticks intact, and Claude can tick or untick an item by adding or removing ` /x`.
- **Read-only notes:** locked, private, archived, slotted (slots 1–9) and trashed notes. Antinote reports "Slotted notes cannot be promoted", and editing archived notes hasn't been tested yet.
- The URL interface caps a note at about 30 KB once percent-encoded.

## Install

Requires macOS 14+, Antinote, and the Xcode Command Line Tools (`xcode-select --install`). There are no other dependencies.

```bash
git clone https://github.com/bt-vdla/antinote-mcp.git
cd antinote-mcp
./build.sh
```

Grant read access once. A folder picker opens on Antinote's data folder; click **Allow Read Access**. Run this again after each rebuild, because a new ad-hoc signature can invalidate the saved permission.

```bash
build/AntinoteMCP.app/Contents/MacOS/antinote-mcp grant
```

```bash
build/AntinoteMCP.app/Contents/MacOS/antinote-mcp status
```

**Claude Code:**

```bash
claude mcp add antinote -s user -- "$PWD/build/AntinoteMCP.app/Contents/MacOS/antinote-mcp"
```

**Claude Desktop.** Add this to `~/Library/Application Support/Claude/claude_desktop_config.json`, using your absolute path:

```json
{
  "mcpServers": {
    "antinote": { "command": "/absolute/path/to/antinote-mcp/build/AntinoteMCP.app/Contents/MacOS/antinote-mcp" }
  }
}
```

Antinote must be running for writes. Reads work whenever the database exists.

## Testing

`scripts/mcp_call.py` is a tiny MCP client:

```bash
python3 scripts/mcp_call.py list
```

```bash
python3 scripts/mcp_call.py call search_notes '{"query":"invoice"}'
```

The end-to-end write test only touches the two `MCPTEST` notes it creates. Delete them afterwards:

```bash
python3 scripts/mcp_call.py e2e
```

## Antinote reference: what we found

The URL actions live at `antinote://x-callback-url/<action>` with percent-encoded parameters. We decoded them from the app (v1.1.x):

| Action | Params | Notes |
|---|---|---|
| `createNote` | `content` | ✅ verified |
| `appendToCurrent` | `content` | Acts on the current note; Antinote inserts blank lines before the text |
| `overwriteCurrent` | `content` | ✅ verified (after `promoteAndOpen`) |
| `promoteAndOpen` | `noteId` (dashed UUID) | ✅ verified; moves the note to the top |
| `togglePin` | `isPinned` | not tested |
| `reloadDB` | — | Harmless, but **can change the current note** and does not refresh notes already in memory |
| `searchNotes` | `searchTerm`, `x-success` | Returns results through a callback; not used (the database read is better) |

The `ZNOTE` columns we use:

- `ZID` (UUID blob)
- `ZCONTENT`
- `Z_OPT` (version)
- `ZDBINDEX` (list order, steps of 10000)
- `ZISARCHIVED`
- `ZSOFTDELETED` with `ZDELETEDAT` (trash)
- `ZISLOCKED`, `ZISPRIVATE`
- `ZISSLOTTED` with `ZSLOTINDEX`
- `ZCREATED`, `ZLASTMODIFIED` (seconds since 2001-01-01)

Checklist rows live in `ZCHECKLISTITEM` as character ranges into the note text. Core Data persistent history is enabled (`ACHANGE`, `ATRANSACTION`). Antinote also makes its own rolling backups, `cd-v1-notes_cdbackup_*.sqlite`, in the same folder.

## Extension: `date_note`

[`extensions/date_note`](extensions/date_note) adds `::new_dated_note`, which opens a new note headed by today's date in bold, such as `**Thursday, 5 Nov 2026**`. The date format can be changed in its preferences. See its [README](extensions/date_note/README.md) to install it.

## Credits

- [maferland/antinote-mcp](https://github.com/maferland/antinote-mcp): the original Antinote MCP server, whose schema decoding and folder-scoped sandbox reader approach this project builds on.
- [johnsonfung/antinote-extensions](https://github.com/johnsonfung/antinote-extensions): Antinote's extension API and docs.
- Antinote by Chabo Makers. This project is unofficial and relies on internal database details that may change between Antinote versions.

## License

MIT — see [LICENSE](LICENSE).
