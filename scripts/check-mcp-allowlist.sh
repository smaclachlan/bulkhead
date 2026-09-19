#!/usr/bin/env bash
# Prototype for ADR-0002 Decision 5 (docs/plans/phase-2-mcp-gateway-investigation.md):
# a narrow, direct-MCP-protocol check that each downstream server exposes
# exactly the tool names it's supposed to - nothing more, nothing less.
# Detection, not enforcement: this reports drift, it doesn't sit in the
# request path.
#
# Runs from inside the orchestrator container, since that's the one
# container in the topology with a network route to both workspace-mcp
# (internal-workspace) and memory-mcp (internal-memory) - see
# docker-compose.yml. Reuses orchestrator's own `mcp<2` pin
# (streamablehttp_client, no underscore - see
# orchestrator/src/orchestrator/chat_client.py) rather than the
# `mcp>=2.2,<3` shape scripts/validate-phase1.sh's embedded client uses for
# workspace-mcp/chat-mcp directly.
#
# Run from the repo root, with the stack already up:
#   sh scripts/check-mcp-allowlist.sh

set -u

checker_py='
import asyncio, json, sys

def _flatten(exc):
    if hasattr(exc, "exceptions"):
        parts = []
        for sub in exc.exceptions:
            parts.extend(_flatten(sub))
        return parts
    return [f"{type(exc).__name__}: {exc}"]

ALLOWLIST = {
    "workspace-mcp": {
        "url": "http://workspace-mcp:8801/mcp",
        "tools": ["exec"],
    },
    "memory-mcp": {
        "url": "http://memory-mcp:8803/mcp",
        "tools": sorted([
            "create_entities", "create_relations", "add_observations",
            "delete_entities", "delete_observations", "delete_relations",
            "read_graph", "search_nodes", "open_nodes",
        ]),
    },
}

async def check_one(name, url, expected):
    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client

    try:
        async with streamablehttp_client(url) as (read, write, _get_session_id):
            async with ClientSession(read, write) as session:
                await session.initialize()
                tools = await session.list_tools()
                got = sorted(t.name for t in tools.tools)
                ok = got == expected
                return {"name": name, "ok": ok, "expected": expected, "got": got}
    except Exception as e:
        return {"name": name, "ok": False, "error": " | ".join(_flatten(e))}

async def main():
    results = await asyncio.gather(
        *(check_one(name, cfg["url"], cfg["tools"]) for name, cfg in ALLOWLIST.items())
    )
    print(json.dumps(list(results)))

asyncio.run(main())
'

result="$(docker compose exec -T orchestrator python3 -c "$checker_py" 2>&1)"
json_line="$(printf '%s\n' "$result" | grep -E '^\[' | tail -1)"

if [ -z "$json_line" ]; then
  echo "[FAIL] could not run the allowlist checker inside orchestrator - raw output:"
  echo "$result"
  exit 1
fi

fail=0
printf '%s' "$json_line" | python3 -c "
import json, sys
rows = json.load(sys.stdin)
fail = False
for r in rows:
    if r.get('ok'):
        print(f\"[PASS] {r['name']} exposes exactly {r['expected']}\")
    else:
        fail = True
        if 'error' in r:
            print(f\"[FAIL] {r['name']}: {r['error']}\")
        else:
            print(f\"[FAIL] {r['name']} tool-surface drift: expected {r['expected']}, got {r['got']}\")
sys.exit(1 if fail else 0)
" || fail=1

exit "$fail"
