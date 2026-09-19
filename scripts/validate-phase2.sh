#!/usr/bin/env bash
# Automated harness for docs/plans/phase-2-validation.md - copied from
# scripts/validate-phase1.sh per that script's own extension note ("copy
# this file to validate-phase2.sh, change PHASE below"). Verifies the three
# headline claims in docs/adr/0002-phase-2-isolation-ux-memory.md: improved
# chat UX, network isolation around the new docker-socket-proxy/memory-mcp
# containers, and memory that survives both a container restart and a
# fresh Orchestrator session - see that ADR's "Testing & Validation"
# section and phase-2-validation.md for the reasoning behind each check.
#
# Run from the repo root, with the stack already up:
#   sh scripts/validate-phase2.sh
#
# Requires: docker, docker compose, curl, python3 all on PATH, and a valid
# ANTHROPIC_API_KEY (same as phase 1 - steps 3, 5 and 7 drive the real
# chat/LLM path).

set -u

PHASE="phase-2"
RESULTS_DIR="validation-results/${PHASE}"
RESULTS_TSV="$(mktemp)"
trap 'rm -f "$RESULTS_TSV"' EXIT

pass=0
fail=0

# record <id> <pass|fail> <description> [detail]
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

# skip <id> <description> [detail] - recorded in the JSON output but not
# counted toward pass/fail, for checks that are legitimately conditional
# (e.g. Kata, only meaningful when WORKSPACE_RUNTIME=kata is set).
skip() {
  id="$1"; desc="$2"; detail="${3:-}"
  detail_one_line="$(printf '%s' "$detail" | tr '\n' '|' | sed 's/|/ | /g')"
  printf '%s\t%s\t%s\t%s\n' "$id" "skip" "$desc" "$detail_one_line" >> "$RESULTS_TSV"
  printf '[SKIP] %s\n' "$desc"
}

abort() {
  echo "$1" >&2
  exit 1
}

if [ ! -f flake.nix ] || [ ! -f docker-compose.yml ]; then
  abort "run this from the pandora repo root"
fi

command -v docker >/dev/null 2>&1 || abort "docker not found on PATH"
command -v curl >/dev/null 2>&1 || abort "curl not found on PATH"
command -v python3 >/dev/null 2>&1 || abort "python3 not found on PATH"
docker compose ps >/dev/null 2>&1 || abort "'docker compose ps' failed - is the stack up (nix run .#up)?"

# ---- Step 1: stack up --------------------------------------------------

echo "== Step 1: stack up (six containers) =="

running_count="$(docker compose ps --status running -q | wc -l | tr -d ' ')"
if [ "$running_count" -eq 6 ]; then
  record step1.all-running pass "all six containers running" "$running_count/6 running"
else
  record step1.all-running fail "all six containers running" "$running_count/6 running"
fi

# ---- Step 2: network segmentation --------------------------------------

echo
echo "== Step 2: network segmentation around the new containers =="

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
check_no_egress memory-mcp
check_no_egress docker-socket-proxy

# Cross-container reachability probes, same style as phase 1's step 7:
# a plain TCP connect test run from inside one container, targeting
# another - answers "can it reach the port at all", independent of the mcp
# SDK's client API shape.
tcp_probe() {
  # tcp_probe <from-service> <target-host> <target-port>
  docker compose exec -T "$1" python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(3)
try:
    s.connect(('$2', $3))
    print('reachable')
except OSError as e:
    print(f'unreachable: {e}')
finally:
    s.close()
" 2>&1
}

probe="$(tcp_probe orchestrator docker-socket-proxy 2375)"
if printf '%s' "$probe" | grep -q '^reachable'; then
  record step2.orchestrator-cannot-reach-proxy fail \
    "orchestrator cannot reach docker-socket-proxy directly (ADR-0002 §3)" "$probe"
else
  record step2.orchestrator-cannot-reach-proxy pass \
    "orchestrator cannot reach docker-socket-proxy directly" "$probe"
fi

probe="$(tcp_probe chat-mcp memory-mcp 8803)"
if printf '%s' "$probe" | grep -q '^reachable'; then
  record step2.chat-cannot-reach-memory fail \
    "chat-mcp cannot reach memory-mcp (ADR-0002 §5)" "$probe"
else
  record step2.chat-cannot-reach-memory pass "chat-mcp cannot reach memory-mcp" "$probe"
fi

probe="$(tcp_probe workspace-mcp memory-mcp 8803)"
if printf '%s' "$probe" | grep -q '^reachable'; then
  record step2.workspace-mcp-cannot-reach-memory fail \
    "workspace-mcp cannot reach memory-mcp (ADR-0002 §5)" "$probe"
else
  record step2.workspace-mcp-cannot-reach-memory pass "workspace-mcp cannot reach memory-mcp" "$probe"
fi

# ---- Find the chat-mcp token, needed for everything below -------------

chat_log="$(docker compose logs chat-mcp 2>/dev/null)"
token="$(printf '%s\n' "$chat_log" | grep -oE 'token=[A-Za-z0-9_-]+' | tail -1 | cut -d= -f2)"

if [ -z "$token" ]; then
  record token.found fail "found chat-mcp token in logs"
else
  record token.found pass "found chat-mcp token in logs"
fi

# ---- Step 3: chat UX - presence + activity -----------------------------

echo
echo "== Step 3: chat UX presence + activity feedback (ADR-0002 Decision 2) =="

if [ -z "${token:-}" ]; then
  record step3.presence-advances fail "skipped - no chat-mcp token"
  record step3.activity-sequence fail "skipped - no chat-mcp token"
else
  # last_seen only updates once per chat_receive call, which blocks for up
  # to CHAT_POLL_TIMEOUT_SECONDS (default 30s) at a time - a gap shorter
  # than that will almost always land inside the same call's window and
  # look like it "didn't advance" even though presence is working fine.
  poll_timeout="$(docker compose exec -T orchestrator printenv CHAT_POLL_TIMEOUT_SECONDS 2>/dev/null | tr -d '[:space:]')"
  [ -n "$poll_timeout" ] || poll_timeout=30
  wait_seconds=$((poll_timeout + 10))

  status1="$(curl -s "http://localhost:8787/api/status?token=${token}")"
  seen1="$(printf '%s' "$status1" | python3 -c "import json,sys; print(json.load(sys.stdin).get('last_seen'))" 2>/dev/null)"
  sleep "$wait_seconds"
  status2="$(curl -s "http://localhost:8787/api/status?token=${token}")"
  seen2="$(printf '%s' "$status2" | python3 -c "import json,sys; print(json.load(sys.stdin).get('last_seen'))" 2>/dev/null)"

  if [ -n "$seen1" ] && [ -n "$seen2" ] && [ "$seen1" != "None" ] && [ "$seen2" != "None" ] \
    && python3 -c "import sys; sys.exit(0 if float('$seen2') > float('$seen1') else 1)" 2>/dev/null; then
    record step3.presence-advances pass "last_seen advances between polls" "$seen1 -> $seen2"
  else
    record step3.presence-advances fail "last_seen advances between polls" "$seen1 -> $seen2"
  fi

  activity_id="$(date +%s)"
  send_code="$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST "http://localhost:8787/api/send?token=${token}" \
    -H 'Content-Type: application/json' \
    -d "{\"text\":\"activity check ${activity_id}: reply with just OK\"}")"

  if [ "$send_code" != "200" ]; then
    record step3.activity-sequence fail "sent activity-check prompt" "POST /api/send returned $send_code"
  else
    seq=""
    for _ in $(seq 1 30); do
      s="$(curl -s "http://localhost:8787/api/status?token=${token}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)"
      case "$seq" in
        *"$s"*) : ;;  # collapse immediate repeats
        *) seq="${seq}${seq:+,}${s}" ;;
      esac
      [ "$s" = "done" ] || [ "$s" = "error" ] && break
      sleep 1
    done

    # "received" is set and then immediately overwritten by "working" in
    # main.py, with no real work happening in between - it exists for at
    # most a few tens of milliseconds, so a 1s-granularity poll (same rate
    # the browser UI itself uses) catching it is best-effort, not
    # guaranteed. Only "working" before "done"/"error" is an actual
    # guarantee worth failing the build over.
    if printf '%s' "$seq" | grep -qE 'working.*(done|error)'; then
      record step3.activity-sequence pass "status passed through working -> done/error in order" "$seq"
    else
      record step3.activity-sequence fail "status passed through working -> done/error in order" "observed: $seq"
    fi
  fi
fi

# ---- Step 4: CLI client -------------------------------------------------

echo
echo "== Step 4: CLI client round-trip (phase-2-scope.md item 3) =="

if [ -z "${token:-}" ]; then
  record step4.cli-roundtrip fail "skipped - no chat-mcp token"
else
  cli_marker="pandora-cli-check-$(date +%s)"
  cli_reply="$(CHAT_MCP_TOKEN="$token" CHAT_UI_URL="http://localhost:8787" \
    python3 chat-mcp/src/chat_mcp/cli.py send \
    "Reply with exactly this text and nothing else: ${cli_marker}" --wait --timeout 60 2>&1)"

  if printf '%s' "$cli_reply" | grep -q "$cli_marker"; then
    record step4.cli-roundtrip pass "chat_mcp.cli send --wait round-tripped a real reply" "$cli_reply"
  else
    record step4.cli-roundtrip fail "chat_mcp.cli send --wait round-tripped a real reply" "$cli_reply"
  fi
fi

# ---- Step 5: docker-socket-proxy is transparent to the real exec path --

echo
echo "== Step 5: workspace_exec still works through docker-socket-proxy (ADR-0002 Decision 3) =="

if [ -z "${token:-}" ]; then
  record step5.tool-use-through-proxy fail "skipped - no chat-mcp token"
else
  run_id="$(date +%s)"
  content="pandora-proxy-check-${run_id}"
  prompt="Run this exact shell command and show me the output: echo ${content}"
  send_code="$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST "http://localhost:8787/api/send?token=${token}" \
    -H 'Content-Type: application/json' \
    -d "{\"text\":\"${prompt}\"}")"

  reply_text=""
  if [ "$send_code" = "200" ]; then
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
  fi

  if printf '%s' "$reply_text" | grep -q "$content"; then
    record step5.tool-use-through-proxy pass "real exec via docker-socket-proxy reflected in reply" "reply contained '$content'"
  else
    record step5.tool-use-through-proxy fail "real exec via docker-socket-proxy reflected in reply" "no matching reply seen within 60s (send HTTP $send_code)"
  fi
fi

# ---- Step 6: memory persistence across a container restart -------------

echo
echo "== Step 6: memory-mcp persistence across a container restart (ADR-0002 Decision 4) =="

memory_marker="pandora-memory-check-$(date +%s)"

mcp_client_common='
import asyncio, json, sys

def _flatten(exc):
    if hasattr(exc, "exceptions"):
        parts = []
        for sub in exc.exceptions:
            parts.extend(_flatten(sub))
        return parts
    return [f"{type(exc).__name__}: {exc}"]
'

write_marker_py="${mcp_client_common}
async def main():
    out = {}
    try:
        from mcp import ClientSession
        from mcp.client.streamable_http import streamablehttp_client
        async with streamablehttp_client('http://memory-mcp:8803/mcp') as (read, write, _sid):
            async with ClientSession(read, write) as session:
                await session.initialize()
                result = await session.call_tool('create_entities', {'entities': [
                    {'name': '${memory_marker}', 'entityType': 'validation-check', 'observations': ['written by scripts/validate-phase2.sh']},
                ]})
                out['ok'] = not bool(getattr(result, 'isError', getattr(result, 'is_error', False)))
    except Exception as e:
        out['error'] = ' | '.join(_flatten(e))
    print(json.dumps(out))
asyncio.run(main())
"

read_marker_py="${mcp_client_common}
async def main():
    out = {}
    try:
        from mcp import ClientSession
        from mcp.client.streamable_http import streamablehttp_client
        async with streamablehttp_client('http://memory-mcp:8803/mcp') as (read, write, _sid):
            async with ClientSession(read, write) as session:
                await session.initialize()
                result = await session.call_tool('open_nodes', {'names': ['${memory_marker}']})
                text = '\n'.join((getattr(b, 'text', '') or '') for b in result.content)
                out['text'] = text
    except Exception as e:
        out['error'] = ' | '.join(_flatten(e))
    print(json.dumps(out))
asyncio.run(main())
"

write_result="$(docker compose exec -T orchestrator python3 -c "$write_marker_py" 2>&1)"
if printf '%s' "$write_result" | grep -q '"ok": true'; then
  record step6.memory-write pass "wrote a marker entity into memory-mcp"
else
  record step6.memory-write fail "wrote a marker entity into memory-mcp" "$write_result"
fi

echo "restarting memory-mcp..."
docker compose restart memory-mcp >/dev/null 2>&1
for _ in $(seq 1 15); do
  sleep 2
  docker compose exec -T orchestrator python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM); s.settimeout(2)
try:
    s.connect(('memory-mcp', 8803)); print('up')
except OSError:
    print('down')
finally:
    s.close()
" 2>/dev/null | grep -q up && break
done

read_result="$(docker compose exec -T orchestrator python3 -c "$read_marker_py" 2>&1)"
if printf '%s' "$read_result" | grep -q "$memory_marker"; then
  record step6.memory-survives-restart pass "marker entity survived a memory-mcp container restart" "$read_result"
else
  record step6.memory-survives-restart fail "marker entity survived a memory-mcp container restart" "$read_result"
fi

# ---- Step 7: memory persistence across a fresh Orchestrator session ----

echo
echo "== Step 7: memory recall across a fresh Orchestrator session (ADR-0002 Decision 4) =="

if [ -z "${token:-}" ]; then
  record step7.cross-session-recall fail "skipped - no chat-mcp token"
else
  session_marker="pandora-session-marker-$(date +%s)"
  remember_prompt="Please remember this for later, using your memory tools: my validation marker for today is ${session_marker}. Just confirm you've stored it, briefly."

  # A reply containing the marker isn't proof anything was actually
  # persisted - the model could just echo it back conversationally
  # without calling a memory_* tool at all. Count mcp-agent's own
  # "Requesting tool call" log lines for server_name "memory" before/after
  # to confirm a real tool call happened, not just a plausible-looking
  # reply.
  mem_calls_before="$(docker compose logs orchestrator 2>/dev/null | grep -c '"server_name": "memory"')"

  curl -s -o /dev/null -X POST "http://localhost:8787/api/send?token=${token}" \
    -H 'Content-Type: application/json' -d "{\"text\":\"${remember_prompt}\"}" >/dev/null

  ack_seen=0
  for _ in $(seq 1 30); do
    sleep 2
    msgs="$(curl -s "http://localhost:8787/api/messages?since=0&token=${token}")"
    if printf '%s' "$msgs" | python3 -c "
import json, sys
data = json.load(sys.stdin)
sys.exit(0 if any(m.get('role') != 'user' and '${session_marker}' in (m.get('text') or '') for m in data.get('messages', [])) else 1)
" 2>/dev/null; then
      ack_seen=1
      break
    fi
  done

  mem_calls_after="$(docker compose logs orchestrator 2>/dev/null | grep -c '"server_name": "memory"')"

  if [ "$ack_seen" -ne 1 ]; then
    record step7.cross-session-recall fail "orchestrator acknowledged storing the marker" "no ack seen within 60s"
  elif [ "$mem_calls_after" -le "$mem_calls_before" ]; then
    record step7.cross-session-recall fail "orchestrator actually called a memory_* tool to store the marker" \
      "replied with the marker but no new memory tool call seen in logs ($mem_calls_before -> $mem_calls_after) - it may have just echoed it conversationally"
  else
    since_before_restart="$(curl -s "http://localhost:8787/api/messages?since=0&token=${token}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(max((m['id'] for m in data.get('messages', [])), default=0))
" 2>/dev/null)"

    echo "restarting orchestrator (fresh conversation, same as a new session)..."
    docker compose restart orchestrator >/dev/null 2>&1
    for _ in $(seq 1 20); do
      sleep 2
      docker compose logs orchestrator 2>/dev/null | grep -q "ready, polling chat" && break
    done

    recall_prompt="Without me repeating it - what validation marker did I ask you to remember earlier in a previous message?"
    curl -s -o /dev/null -X POST "http://localhost:8787/api/send?token=${token}" \
      -H 'Content-Type: application/json' -d "{\"text\":\"${recall_prompt}\"}" >/dev/null

    recalled=0
    for _ in $(seq 1 30); do
      sleep 2
      msgs="$(curl -s "http://localhost:8787/api/messages?since=${since_before_restart}&token=${token}")"
      if printf '%s' "$msgs" | python3 -c "
import json, sys
data = json.load(sys.stdin)
sys.exit(0 if any(m.get('role') != 'user' and '${session_marker}' in (m.get('text') or '') for m in data.get('messages', [])) else 1)
" 2>/dev/null; then
        recalled=1
        break
      fi
    done

    if [ "$recalled" -eq 1 ]; then
      record step7.cross-session-recall pass "a fresh orchestrator process recalled the marker via memory_* tools, unprompted"
    else
      record step7.cross-session-recall fail "a fresh orchestrator process recalled the marker via memory_* tools" "no matching reply seen within 60s after restart"
    fi
  fi
fi

# ---- Step 8: Kata runtime (only if explicitly opted in) ----------------

echo
echo "== Step 8: Kata runtime (ADR-0002 Decision 1, opt-in) =="

if [ "${WORKSPACE_RUNTIME:-runc}" != "kata" ]; then
  skip step8.kata-runtime "Kata runtime check (WORKSPACE_RUNTIME != kata - expected on a checkout without Kata installed)"
else
  runtime="$(docker inspect pandora-workspace --format '{{.HostConfig.Runtime}}' 2>/dev/null)"
  if [ "$runtime" = "kata" ]; then
    record step8.kata-runtime pass "pandora-workspace's runtime is 'kata'"
  else
    record step8.kata-runtime fail "pandora-workspace's runtime is 'kata'" "got '$runtime'"
  fi
fi

# ---- Step 9: MCP tool-surface allowlist ---------------------------------

echo
echo "== Step 9: MCP tool-surface allowlist (ADR-0002 Decision 5 prototype) =="

if allowlist_out="$(sh scripts/check-mcp-allowlist.sh 2>&1)"; then
  record step9.mcp-allowlist pass "workspace-mcp/memory-mcp tool surfaces match the allowlist" "$allowlist_out"
else
  record step9.mcp-allowlist fail "workspace-mcp/memory-mcp tool surfaces match the allowlist" "$allowlist_out"
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
        'skip': sum(1 for r in rows if r['status'] == 'skip'),
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
