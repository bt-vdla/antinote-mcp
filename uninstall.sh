#!/bin/zsh
# Unregister Antinote MCP from Claude Code and Claude Desktop. Your notes are never touched.
#   ./uninstall.sh          unregister only
#   ./uninstall.sh --purge  also delete the build and the server's data (folder permission + edit journal)
set -euo pipefail
cd "${0:A:h}"
DESKTOP_CFG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"

command -v claude >/dev/null 2>&1 && claude mcp remove antinote -s user 2>/dev/null && echo "Removed from Claude Code." || true

if [[ -f "$DESKTOP_CFG" ]]; then
  /usr/bin/python3 -I - "$DESKTOP_CFG" <<'EOF'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
if cfg.get("mcpServers", {}).pop("antinote", None) is not None:
    json.dump(cfg, open(p, "w"), indent=2); print("Removed from Claude Desktop (restart it).")
EOF
fi

if [[ "${1:-}" == "--purge" ]]; then
  rm -rf build
  rm -rf "$HOME/Library/Containers/io.github.bt-vdla.antinote-mcp"
  echo "Deleted build/ and the server's data (folder permission and edit journal)."
fi
