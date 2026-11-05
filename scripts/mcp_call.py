#!/usr/bin/env python3
"""Tiny MCP client for manual testing: starts the server, initializes, runs tool calls.

Usage:
  scripts/mcp_call.py list                       # list tools
  scripts/mcp_call.py call <tool> '<json args>'  # call one tool
  scripts/mcp_call.py e2e                        # end-to-end write test on throwaway notes only
"""
import json, subprocess, sys, os

SERVER = os.environ.get("ANTINOTE_MCP",
    os.path.join(os.path.dirname(__file__), "..", "build", "AntinoteMCP.app", "Contents", "MacOS", "antinote-mcp"))


class Client:
    def __init__(self):
        self.p = subprocess.Popen([SERVER, "serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.n = 0
        self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "0"}})
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n"); self.p.stdin.flush()

    def rpc(self, method, params):
        self.n += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params}) + "\n")
        self.p.stdin.flush()
        msg = json.loads(self.p.stdout.readline())
        if "error" in msg:
            raise RuntimeError(msg["error"])
        return msg["result"]

    def call(self, tool, args=None, expect_error=False):
        r = self.rpc("tools/call", {"name": tool, "arguments": args or {}})
        text = r["content"][0]["text"]
        if r.get("isError") and not expect_error:
            raise RuntimeError(f"{tool} failed: {text}")
        if expect_error and not r.get("isError"):
            raise RuntimeError(f"{tool} should have failed but returned: {text}")
        return text if r.get("isError") else json.loads(text)


def e2e():
    c = Client()
    step = lambda s: print(f"\n== {s}")
    step("create two throwaway notes")
    a = c.call("create_note", {"content": "MCPTEST A (safe to delete)\nlist\nalpha /x\nbeta"})["created"]
    b = c.call("create_note", {"content": "MCPTEST B (safe to delete)\ngamma\ndelta"})["created"]
    print(a["short_id"], b["short_id"])

    step("get_note + dry-run edit")
    na = c.call("get_note", {"id": a["short_id"]})
    print(c.call("edit_note", {"id": na["id"], "expected_version": na["version"], "edits": [{"find": "beta", "replace": "beta edited"}], "dry_run": True})["diff"])

    step("stale version is refused")
    print(c.call("edit_note", {"id": na["id"], "expected_version": na["version"] - 1, "append": "x"}, expect_error=True)[:90])

    step("real edit keeps the /x tick")
    r = c.call("edit_note", {"id": na["id"], "expected_version": na["version"], "edits": [{"find": "beta", "replace": "beta edited"}]})
    na = c.call("get_note", {"id": na["id"]})
    assert "alpha /x" in na["content"] and "beta edited" in na["content"], na["content"]
    print("ok:", na["content"].replace("\n", " | "))

    step("undo_last_edit, then check")
    c.call("undo_last_edit", {"id": na["id"]})
    na = c.call("get_note", {"id": na["id"]})
    assert na["content"].endswith("beta"), na["content"]
    print("ok:", na["content"].replace("\n", " | "))

    step("merge B into A (target existing), B gets tombstoned")
    nb = c.call("get_note", {"id": b["id"]})
    merged = na["content"] + "\ngamma\ndelta"
    m = c.call("merge_notes", {"source_ids": [nb["id"]], "target_id": na["id"], "merged_content": merged,
                                "expected_versions": {na["id"]: na["version"], nb["id"]: nb["version"]}})
    print(json.dumps(m, indent=1, ensure_ascii=False)[:600])
    nb = c.call("get_note", {"id": b["id"]})
    assert nb["content"].startswith("🗑️ SAFE TO DELETE"), nb["content"]

    step("search skips tombstones by default")
    s = c.call("search_notes", {"query": "MCPTEST"})
    print([x["short_id"] for x in s["results"]], "tombstone hidden:", b["short_id"] not in [x["short_id"] for x in s["results"]])

    step("tombstone A too, then list_tombstones")
    na = c.call("get_note", {"id": a["id"]})
    c.call("tombstone_note", {"id": na["id"], "expected_version": na["version"], "reason": "smoke test note"})
    t = c.call("list_tombstones")
    print(t["count"], [x["header"][:80] for x in t["tombstones"]])
    print("\nE2E OK — delete the two MCPTEST notes in Antinote.")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "list"
    if cmd == "e2e":
        e2e()
    elif cmd == "list":
        print("\n".join(t["name"] for t in Client().rpc("tools/list", {})["tools"]))
    elif cmd == "call":
        out = Client().call(sys.argv[2], json.loads(sys.argv[3]) if len(sys.argv) > 3 else {})
        print(json.dumps(out, indent=2, ensure_ascii=False) if not isinstance(out, str) else out)
