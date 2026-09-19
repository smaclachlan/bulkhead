#!/usr/bin/env bash
# Automated harness for docs/plans/phase-1-validation.md - runs every check
# in that runbook (steps 1-6) against a live `nix run .#up` stack, and writes
# a timestamped, structured result record under validation-results/phase-1/
# so there's a durable attestation trail of how the containment properties
# held up over time, not just a pass/fail shown once in a terminal.
#
# Run from the repo root, with the stack already up:
#   sh scripts/validate-phase1.sh
#
# Requires: docker, docker compose, curl, python3 all on PATH.
#
# Extending for a later phase: copy this file to validate-phase2.sh, change
# PHASE below, and add check_step*_ functions for whatever that phase's own
# runbook defines - `record` and the JSON writer at the bottom are already
# phase-agnostic.

set -u

PHASE="phase-1"
RESULTS_DIR="validation-results/${PHASE}"
RESULTS_TSV="$(mktemp)"
trap 'rm -f "$RESULTS_TSV"' EXIT

pass=0
fail=0

# record <id> <pass|fail> <description> [detail]
# Appends a TSV row (newlines in detail collapsed to " | ") and prints it.
record() {
  id="$1"; status="$2"; desc="$3"; detail="${4:-}"
  detail_one_line="$(printf '%s' "$detail" | tr '\n' '|' | sed 's/|/ | /g')"
  printf '%s\t%s\t%s\t%s\n' "$id" "$status" "$desc" "$detail_one_line" >> "$RESULTS_TSV"
  if [ "$status" = "pass" ]; then
    printf '[PASS] %s\n' "$desc"
    pass=$((pass + 1))
  else
    printf '[FAIL] %s\n' "$desc"
    [ -n "$detail" ] && printf '       %s\n' "$detail_one_line"
    fail=$((fail + 1))
  fi
}

abort() {
  echo "$1" >&2
  exit 1
}

if [ ! -f flake.nix ] || [ ! -f docker-compose.yml ]; then
  abort "run this from the axle repo root"
fi

command -v docker >/dev/null 2>&1 || abort "docker not found on PATH"
command -v curl >/dev/null 2>&1 || abort "curl not found on PATH"
command -v python3 >/dev/null 2>&1 || abort "python3 not found on PATH"
docker compose ps >/dev/null 2>&1 || abort "'docker compose ps' failed - is the stack up (nix run .#up)?"

# ---- Step 1: stack is up ----------------------------------------------

echo "== Step 1: stack up =="

running_count="$(docker compose ps --status running -q | wc -l | tr -d ' ')"
if [ "$running_count" -eq 4 ]; then
  record step1.all-running pass "all four containers running" "$running_count/4 running"
else
  record step1.all-running fail "all four containers running" "$running_count/4 running"
fi

if docker compose logs chat-mcp 2>/dev/null | grep -q "chat UI: http"; then
  record step1.chat-url-logged pass "chat-mcp logged its UI URL"
else
  record step1.chat-url-logged fail "chat-mcp logged its UI URL"
fi

# ---- Step 2: network segmentation --------------------------------------

echo
echo "== Step 2: network segmentation =="

netmode="$(docker inspect axle-workspace --format '{{.HostConfig.NetworkMode}}' 2>/dev/null)"
if [ "$netmode" = "none" ]; then
  record step2.workspace-no-network pass "axle-workspace NetworkMode is 'none'"
else
  record step2.workspace-no-network fail "axle-workspace NetworkMode check" "got '$netmode'"
fi

check_no_egress() {
  service="$1"
  if docker compose exec -T "$service" python3 -c \
    "import urllib.request; urllib.request.urlopen('https://example.com', timeout=3)" \
    >/dev/null 2>&1; then
    record "step2.${service}-no-egress" fail "$service has no internet egress" "urlopen unexpectedly succeeded"
  else
    record "step2.${service}-no-egress" pass "$service has no internet egress"
  fi
}
check_no_egress chat-mcp
check_no_egress workspace-mcp

# ---- Step 3: chat UI + auth gate ---------------------------------------

echo
echo "== Step 3: chat UI + auth gate =="

chat_log="$(docker compose logs chat-mcp 2>/dev/null)"
token="$(printf '%s\n' "$chat_log" | grep -oE 'token=[A-Za-z0-9_-]+' | tail -1 | cut -d= -f2)"

if [ -z "$token" ]; then
  record step3.token-found fail "found chat-mcp token in logs"
else
  record step3.token-found pass "found chat-mcp token in logs"

  code_no_token="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:8787/")"
  if [ "$code_no_token" = "403" ]; then
    record step3.auth-gate pass "chat UI without token returns 403"
  else
    record step3.auth-gate fail "chat UI without token returns 403" "got HTTP $code_no_token"
  fi

  code_with_token="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:8787/?token=${token}")"
  if [ "$code_with_token" = "200" ]; then
    record step3.ui-loads pass "chat UI with token returns 200"
  else
    record step3.ui-loads fail "chat UI with token returns 200" "got HTTP $code_with_token"
  fi
fi

# ---- Steps 4 & 5: real tool use + containment --------------------------

echo
echo "== Steps 4-5: tool use through workspace_exec + containment =="

if [ -z "${token:-}" ]; then
  record step4.tool-use fail "skipped - no chat-mcp token"
  record step5.file-in-container fail "skipped - no chat-mcp token"
  record step5.no-host-leak fail "skipped - no chat-mcp token"
  record step5.audit-logged fail "skipped - no chat-mcp token"
else
  run_id="$(date +%s)"
  marker="axle-validate-${run_id}"
  fname="${marker}.txt"
  content="harness-check-${run_id}"

  exec_log_before="$(docker compose logs workspace-mcp 2>/dev/null | grep -c '\[workspace-mcp\] exec')"

  prompt="Run this exact shell command and show me the output: echo ${content} > ${fname} && cat ${fname}"
  send_code="$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST "http://localhost:8787/api/send?token=${token}" \
    -H 'Content-Type: application/json' \
    -d "{\"text\":\"${prompt}\"}")"

  if [ "$send_code" != "200" ]; then
    record step4.tool-use fail "sent tool-use prompt" "POST /api/send returned $send_code"
  else
    reply_text=""
    for _ in $(seq 1 30); do
      sleep 2
      msgs="$(curl -s "http://localhost:8787/api/messages?since=0&token=${token}")"
      reply_text="$(printf '%s' "$msgs" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for m in data.get('messages', []):
    if m.get('role') != 'user' and '${run_id}' in (m.get('text') or ''):
        print(m['text'])
        break
" 2>/dev/null)"
      [ -n "$reply_text" ] && break
    done

    if [ -n "$reply_text" ] && printf '%s' "$reply_text" | grep -q "$content"; then
      record step4.tool-use pass "reply reflects real command output" "reply contained '$content'"
    else
      record step4.tool-use fail "reply reflects real command output" "no matching reply seen within 60s"
    fi
  fi

  exec_log_after="$(docker compose logs workspace-mcp 2>/dev/null | grep -c '\[workspace-mcp\] exec')"
  if [ "$exec_log_after" -gt "$exec_log_before" ]; then
    record step5.audit-logged pass "workspace-mcp logged a new exec call" "$exec_log_before -> $exec_log_after"
  else
    record step5.audit-logged fail "workspace-mcp logged a new exec call" "$exec_log_before -> $exec_log_after"
  fi

  in_container="$(docker exec axle-workspace sh -c "cat ${fname}" 2>&1)"
  if [ "$in_container" = "$content" ]; then
    record step5.file-in-container pass "file independently re-read inside axle-workspace" "contents: $in_container"
  else
    record step5.file-in-container fail "file independently re-read inside axle-workspace" "got: $in_container"
  fi

  host_hit="$(find . -maxdepth 2 -iname "${fname}" 2>/dev/null)"
  if [ -z "$host_hit" ]; then
    record step5.no-host-leak pass "no ${fname} leaked onto the host filesystem"
  else
    record step5.no-host-leak fail "no ${fname} leaked onto the host filesystem" "found at $host_hit"
  fi
fi

# ---- Step 6: no-op turn survives ---------------------------------------

echo
echo "== Step 6: no-op turn survives =="

if [ -z "${token:-}" ]; then
  record step6.no-op-survives fail "skipped - no chat-mcp token"
else
  orch_id="$(docker compose ps -q orchestrator 2>/dev/null)"
  restarts_before="$(docker inspect --format '{{.RestartCount}}' "$orch_id" 2>/dev/null)"

  noop_id="$(date +%s)"
  send_code="$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST "http://localhost:8787/api/send?token=${token}" \
    -H 'Content-Type: application/json' \
    -d "{\"text\":\"hi (automated no-op check ${noop_id}, no tool use needed, reply briefly)\"}")"

  if [ "$send_code" != "200" ]; then
    record step6.no-op-survives fail "sent no-op message" "POST /api/send returned $send_code"
  else
    reply_found=0
    for _ in $(seq 1 30); do
      sleep 2
      msgs="$(curl -s "http://localhost:8787/api/messages?since=0&token=${token}")"
      if printf '%s' "$msgs" | python3 -c "
import json, sys
data = json.load(sys.stdin)
sys.exit(0 if any(m.get('role') != 'user' for m in data.get('messages', [])) else 1)
" 2>/dev/null; then
        reply_found=1
        break
      fi
    done

    restarts_after="$(docker inspect --format '{{.RestartCount}}' "$orch_id" 2>/dev/null)"
    if [ "$reply_found" -eq 1 ] && [ "$restarts_before" = "$restarts_after" ]; then
      record step6.no-op-survives pass "loop survived a no-op turn without restarting" "restarts: $restarts_before -> $restarts_after"
    else
      record step6.no-op-survives fail "loop survived a no-op turn without restarting" "reply_found=$reply_found restarts: $restarts_before -> $restarts_after"
    fi
  fi
fi

# ---- Step 7: direct MCP protocol checks --------------------------------
#
# Everything above drives workspace_exec through the chat -> LLM -> Orchestrator
# path. These checks instead speak MCP directly to workspace-mcp's own /mcp
# endpoint, bypassing the LLM entirely - real tool listing, real schema
# inspection, real exec calls, and a real cross-container reachability probe.
# This is best-effort against the `mcp` Python SDK's client API as of the
# `mcp>=2.2.0,<3` pin in workspace-mcp/chat-mcp's requirements.txt - if the
# SDK's client shape has moved, the JSON below will show a Python traceback
# in "detail" rather than silently passing.

echo
echo "== Step 7: direct MCP protocol checks (bypassing the LLM) =="

# Host -> workspace-mcp should be impossible: no port is published for it in
# docker-compose.yml (only chat-mcp publishes 8787). Confirms that directly.
if curl -s -m 3 -o /dev/null "http://localhost:8801/mcp" 2>/dev/null; then
  record step7.host-cannot-reach fail "workspace-mcp's :8801 is not reachable from the host" "curl unexpectedly connected"
else
  record step7.host-cannot-reach pass "workspace-mcp's :8801 is not reachable from the host"
fi

mcp_client_py='
import asyncio, json, sys

def _flatten(exc):
    # ExceptionGroup (anyio TaskGroups use these internally) stringifies as
    # a useless "unhandled errors in a TaskGroup (N sub-exception)" unless
    # you walk .exceptions yourself - unwrap recursively so failures here
    # are actually diagnosable instead of hiding the real cause.
    if hasattr(exc, "exceptions"):
        parts = []
        for sub in exc.exceptions:
            parts.extend(_flatten(sub))
        return parts
    return [f"{type(exc).__name__}: {exc}"]

async def main():
    out = {}
    try:
        from mcp import ClientSession
        # NOTE: this runs inside the workspace-mcp/chat-mcp container,
        # which pins mcp>=2.2,<3 - confirmed live (2026-09-19 run) that
        # this version exports streamable_http_client (with the
        # underscore), unlike orchestrator/src/orchestrator/chat_client.py,
        # which imports streamablehttp_client (no underscore) but runs
        # under orchestrator own separate mcp<2 pin. The two containers
        # pin different mcp major versions on purpose (see requirements.txt
        # comments) so this name is deliberately not copied from that file.
        from mcp.client.streamable_http import streamable_http_client

        url, mode, marker = sys.argv[1], sys.argv[2], sys.argv[3]
        async with streamable_http_client(url) as streams:
            read, write = streams[0], streams[1]
            async with ClientSession(read, write) as session:
                await session.initialize()
                tools = await session.list_tools()
                out["tools"] = sorted(t.name for t in tools.tools)
                exec_tool = next((t for t in tools.tools if t.name == "exec"), None)
                if exec_tool is not None:
                    # mcp>=2 renamed some Tool/CallToolResult fields to
                    # snake_case (confirmed live 2026-09-19:
                    # AttributeError on .inputSchema) - try both spellings
                    # rather than hardcode one SDK major version shape.
                    schema = getattr(exec_tool, "inputSchema", None)
                    if schema is None:
                        schema = getattr(exec_tool, "input_schema", None)
                    props = (schema or {}).get("properties", {})
                    out["exec_schema_props"] = sorted(props.keys())

                if mode == "exec":
                    result = await session.call_tool("exec", {"command": f"echo {marker}"})
                elif mode == "escape":
                    result = await session.call_tool(
                        "exec",
                        {"command": f"echo {marker}-start; docker ps; echo {marker}-end"},
                    )
                else:
                    result = None

                if result is not None:
                    text = "\n".join((getattr(b, "text", "") or "") for b in result.content)
                    out["exec_text"] = text
                    is_error = getattr(result, "isError", None)
                    if is_error is None:
                        is_error = getattr(result, "is_error", False)
                    out["is_error"] = bool(is_error)
    except Exception as e:
        out["error"] = " | ".join(_flatten(e))

    print(json.dumps(out))

asyncio.run(main())
'

# Write the client script into a container via stdin (docker compose exec -T
# disables the pseudo-tty so a heredoc can be piped in as stdin).
write_mcp_client() {
  docker compose exec -T "$1" python3 -c "import sys; open('/tmp/axle_mcp_check.py','w').write(sys.stdin.read())" <<PYEOF
$mcp_client_py
PYEOF
}

run_mcp_check() {
  # run_mcp_check <service> <url> <mode> <marker>
  docker compose exec -T "$1" python3 /tmp/axle_mcp_check.py "$2" "$3" "$4" 2>&1
}

extract_json() {
  # Pulls the last line that looks like a JSON object out of possibly-noisy
  # output (stray stderr, warnings, etc.)
  printf '%s\n' "$1" | grep -E '^\{' | tail -1
}

write_mcp_client workspace-mcp >/dev/null 2>&1
write_mcp_client chat-mcp >/dev/null 2>&1

marker7="axle-mcp-check-$(date +%s)"
raw="$(run_mcp_check workspace-mcp "http://localhost:8801/mcp" exec "$marker7")"
json_line="$(extract_json "$raw")"

if [ -z "$json_line" ]; then
  record step7.tool-listing fail "direct MCP list_tools/exec against workspace-mcp" "no parseable JSON - raw: $raw"
else
  eval "$(printf '%s' "$json_line" | python3 -c "
import json, sys, shlex
d = json.load(sys.stdin)
def sh(v):
    return shlex.quote(json.dumps(v) if not isinstance(v, str) else v)
print('tools_val=' + sh(d.get('tools')))
print('props_val=' + sh(d.get('exec_schema_props')))
print('exec_text_val=' + sh(d.get('exec_text', '')))
print('is_error_val=' + sh(str(d.get('is_error'))))
print('error_val=' + sh(d.get('error', '')))
")"

  if [ -n "$error_val" ]; then
    record step7.tool-listing fail "direct MCP client connected to workspace-mcp" "$error_val"
  else
    if [ "$tools_val" = '["exec"]' ]; then
      record step7.tool-listing pass "workspace-mcp exposes exactly one tool: exec"
    else
      record step7.tool-listing fail "workspace-mcp exposes exactly one tool: exec" "got $tools_val"
    fi

    if [ "$props_val" = '["command"]' ]; then
      record step7.schema-narrow pass "exec tool's schema exposes only 'command' (no target-selection field)"
    else
      record step7.schema-narrow fail "exec tool's schema exposes only 'command'" "got $props_val"
    fi

    if printf '%s' "$exec_text_val" | grep -q "$marker7" && [ "$is_error_val" = "False" ]; then
      record step7.direct-exec pass "direct (non-LLM) exec call ran for real inside the Workspace container" "output: $exec_text_val"
    else
      record step7.direct-exec fail "direct (non-LLM) exec call ran for real" "text=$exec_text_val is_error=$is_error_val"
    fi
  fi
fi

marker7b="axle-mcp-escape-$(date +%s)"
raw_escape="$(run_mcp_check workspace-mcp "http://localhost:8801/mcp" escape "$marker7b")"
json_escape="$(extract_json "$raw_escape")"
escape_text="$(printf '%s' "$json_escape" | python3 -c "import json,sys; print(json.load(sys.stdin).get('exec_text',''))" 2>/dev/null)"

if printf '%s' "$escape_text" | grep -q "${marker7b}-start" && printf '%s' "$escape_text" | grep -q "${marker7b}-end" \
  && ! printf '%s' "$escape_text" | grep -qi "CONTAINER ID"; then
  record step7.no-docker-in-workspace pass "'docker ps' inside the Workspace container fails (no docker CLI there)" "output: $escape_text"
else
  record step7.no-docker-in-workspace fail "'docker ps' inside the Workspace container fails" "output: $escape_text"
fi

# Cross-container reachability: chat-mcp and workspace-mcp share the same
# `internal` Compose network. The ADR (§1) states workspace-mcp should be
# "reachable from Orchestrator only" - Compose's `internal: true` blocks
# egress to the outside world, but doesn't isolate members of the same
# network from each other. Report what's actually true rather than assume
# the ADR's intent is enforced. Deliberately a plain TCP connect test, not
# an MCP-protocol call - this only needs to answer "can it reach the port at
# all", and shouldn't be at the mercy of the mcp SDK's client API shape.
tcp_probe="$(docker compose exec -T chat-mcp python3 -c "
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(3)
try:
    s.connect(('workspace-mcp', 8801))
    print('reachable')
except OSError as e:
    print(f'unreachable: {e}')
finally:
    s.close()
" 2>&1)"

if printf '%s' "$tcp_probe" | grep -q '^reachable'; then
  record step7.cross-container-isolation fail \
    "chat-mcp cannot reach workspace-mcp's port (per ADR-0001 section 1)" \
    "chat-mcp opened a TCP connection to workspace-mcp:8801 - the 'internal' Compose network doesn't isolate members from each other, only from the outside world. Real gap vs. the ADR's stated intent, not a phase-1 blocker but worth tracking (e.g. a phase-2 network policy or splitting workspace-mcp onto its own network reachable only by orchestrator)."
else
  record step7.cross-container-isolation pass "chat-mcp cannot reach workspace-mcp's port" "$tcp_probe"
fi

# ---- Write the attestation record --------------------------------------

echo
echo "== Summary: $pass passed, $fail failed =="

mkdir -p "$RESULTS_DIR"
ts="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
out_file="${RESULTS_DIR}/${ts}.json"
git_commit="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
git_dirty="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"

python3 -c "
import json, sys

rows = []
with open(sys.argv[1], encoding='utf-8') as f:
    for line in f:
        line = line.rstrip('\n')
        if not line:
            continue
        parts = line.split('\t')
        parts += [''] * (4 - len(parts))
        rows.append({
            'id': parts[0],
            'status': parts[1],
            'description': parts[2],
            'detail': parts[3],
        })

record = {
    'phase': sys.argv[2],
    'timestamp_utc': sys.argv[3],
    'git_commit': sys.argv[4],
    'git_dirty': sys.argv[5] != '0',
    'checks': rows,
    'summary': {
        'pass': sum(1 for r in rows if r['status'] == 'pass'),
        'fail': sum(1 for r in rows if r['status'] == 'fail'),
        'total': len(rows),
    },
}

with open(sys.argv[6], 'w', encoding='utf-8') as f:
    json.dump(record, f, indent=2)
    f.write('\n')
" "$RESULTS_TSV" "$PHASE" "$ts" "$git_commit" "$git_dirty" "$out_file"

cp "$out_file" "${RESULTS_DIR}/latest.json"
echo "Results written to ${out_file} (and ${RESULTS_DIR}/latest.json)"

[ "$fail" -eq 0 ]
