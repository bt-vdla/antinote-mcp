#!/bin/zsh
# One command to build, grant access, and register Antinote MCP with Claude.
# Safe to re-run any time (after pulling updates, or if something stopped working).
#
#   ./install.sh             build + grant + register with Claude Code, and ask about Claude Desktop
#   ./install.sh --desktop   also register with the Claude Desktop chat app without asking
#   ./install.sh --no-desktop
set -euo pipefail
cd "${0:A:h}"

BIN="$PWD/build/AntinoteMCP.app/Contents/MacOS/antinote-mcp"
DESKTOP_CFG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
say() { print -P "%F{cyan}==>%f $*"; }

xcrun --find swiftc >/dev/null 2>&1 || { echo "Install the Xcode Command Line Tools first: xcode-select --install"; exit 1; }
[[ -d /Applications/Antinote.app ]] || say "Warning: Antinote.app not found in /Applications."

say "Building"
./build.sh >/dev/null
say "Built $BIN"

say "Checking folder access (a picker opens only if access is missing)"
"$BIN" grant
"$BIN" status | sed -n '/"notes"/,/}/p'

if command -v claude >/dev/null 2>&1; then
  say "Registering with Claude Code (all projects)"
  claude mcp remove antinote -s user >/dev/null 2>&1 || true
  claude mcp add antinote -s user -- "$BIN" >/dev/null
  claude mcp get antinote | grep -E 'Status' || true
else
  say "Claude Code CLI not found; skipping. Later: claude mcp add antinote -s user -- \"$BIN\""
fi

want_desktop=""
case "${1:-}" in
  --desktop) want_desktop=y ;;
  --no-desktop) want_desktop=n ;;
  *) if [[ -t 0 ]]; then read "want_desktop?Also add it to the Claude Desktop chat app? [y/N] "; fi ;;
esac
if [[ "$want_desktop" == [yY]* ]]; then
  say "Registering with Claude Desktop"
  mkdir -p "${DESKTOP_CFG:h}"
  [[ -f "$DESKTOP_CFG" ]] && cp "$DESKTOP_CFG" "$DESKTOP_CFG.bak-$(date +%Y%m%d-%H%M%S)"
  /usr/bin/python3 -I - "$DESKTOP_CFG" "$BIN" <<'EOF'
import json, os, sys
path, binary = sys.argv[1], sys.argv[2]
cfg = json.load(open(path)) if os.path.exists(path) and os.path.getsize(path) else {}
cfg.setdefault("mcpServers", {})["antinote"] = {"command": binary}
json.dump(cfg, open(path, "w"), indent=2)
print("   updated", path)
EOF
  say "Quit and reopen Claude Desktop to load it."
fi

say "Done. Start a new Claude session and ask: “list my recent Antinote notes”."
