# date_note — Antinote extension

Gives you a new note that starts with today's date in bold:

```
**Thursday, 5 Nov 2026**

```

## Commands

| Command | What it does |
|---|---|
| `new_dated_note` | Opens a **brand-new note** with the bold date at the top (via Antinote's own `antinote://x-callback-url/createNote` URL). |
| `date_header` | Fallback: replaces the current line with the bold date. Use it in an empty note (⌘N) if `new_dated_note` ever stops working. |

Type `::new_dated_note` in any note and press Tab or Enter. You can alias it to something shorter (e.g. `::nd`) in Preferences > Extensions.

## Preferences (Preferences > Extensions > date_note)

- **Date Format**: `Thursday, 5 Nov 2026` (default), `5 November 2026`, `November 5, 2026` or `2026-11-05`
- **Blank lines after date**: 0, 1 (default) or 2

## Install

1. Copy this folder into Antinote's Extensions folder and name it `date_note`. The Extensions folder is
   `~/Library/Containers/com.chabomakers.Antinote/Data/Library/Application Support/Antinote/Extensions`;
   Preferences > Extensions shows the exact path.
2. Preferences > Extensions > **Reload Extensions**.

## Test

`./test/run-jsc.sh <path-to-antinote-extensions-base.js>` runs both commands in macOS's JavaScriptCore
with mocked preferences. The base file is `antinote-extensions-base-v0.0.1.js` from
https://github.com/johnsonfung/antinote-extensions.

## Privacy

`dataScope: "none"`: the extension never sees your note text, and it makes no network calls.
