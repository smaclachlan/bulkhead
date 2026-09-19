#!/usr/bin/env bash
# Automated harness for docs/plans/phase-3-validation.md - copied from
# scripts/validate-phase2.sh per that script's own extension note. Verifies
# the claims in docs/adr/0003-phase-3-git-mcp.md: local git ops work through
# the real chat/LLM path, a disallowed branch is rejected server-side, a
# push cannot happen without an explicit human "approve <id>" reply, the
# working tree is genuinely shared between workspace and git-mcp, and the
# admin tools (push_execute/pending_push/push_cancel) never reach the LLM's
# own config - see that ADR's "Testing & Validation" section and
# phase-3-validation.md for the reasoning behind each check.
#
# Run from the repo root, with the stack already up:
#   sh scripts/validate-phase3.sh
#
# Requires: docker, docker compose, curl, python3 all on PATH, and a valid
# ANTHROPIC_API_KEY (steps 4 and 7-9 drive the real chat/LLM path).
#
# Steps 7-9 are opt-in: they only run if git-mcp's own container
# environment has GIT_REMOTE_URL set (checked live via `docker compose exec
# git-mcp printenv`, not this script's own shell env) - see
# phase-3-validation.md for why, and what a scratch repo for them needs.

set -u

PHASE="phase-3"
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
# (steps 7-9, only meaningful once GIT_REMOTE_URL is configured).
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
  abort "run this from the bulkhead repo root"
fi

command -v docker >/dev/null 2>&1 || abort "docker not found on PATH"
command -v curl >/dev/null 2>&1 || abort "curl not found on PATH"
command -v python3 >/dev/null 2>&1 || abort "python3 not found on PATH"
docker compose ps >/dev/null 2>&1 || abort "'docker compose ps' failed - is the stack up (nix run .#up)?"

# ---- Step 1: stack up --------------------------------------------------

echo "== Step 1: stack up (seven containers) =="

running_count="$(docker compose ps --status running -q | wc -l | tr -d ' ')"
if [ "$running_count" -eq 7 ]; then
  record step1.all-running pass "all seven containers running" "$running_count/7 running"
else
  record step1.all-running fail "all seven containers running" "$running_count/7 running"
fi

# ---- Step 2: network segmentation around git-mcp -----------------------

echo
echo "== Step 2: git-mcp reachable only from orchestrator (ADR-0003 §5) =="

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

for from_service in workspace-mcp chat-mcp memory-mcp; do
  for port_pair in "8805:llm" "8806:admin"; do
    port="${port_pair%%:*}"
    label="${port_pair##*:}"
    probe="$(tcp_probe "$from_service" git-mcp "$port")"
    check_id="step2.${from_service}-cannot-reach-git-${label}"
    if printf '%s' "$probe" | grep -q '^reachable'; then
      record "$check_id" fail "$from_service cannot reach git-mcp's $label port ($port)" "$probe"
    else
      record "$check_id" pass "$from_service cannot reach git-mcp's $label port ($port)" "$probe"
    fi
  done
done

# ---- Find the chat-mcp token, needed for steps 4/7/8/9 ------------------

chat_log="$(docker compose logs chat-mcp 2>/dev/null)"
token="$(printf '%s\n' "$chat_log" | grep -oE 'token=[A-Za-z0-9_-]+' | tail -1 | cut -d= -f2)"

if [ -z "$token" ]; then
  record token.found fail "found chat-mcp token in logs"
else
  record token.found pass "found chat-mcp token in logs"
fi

# ---- Step 3: shared working-tree volume ---------------------------------

echo
echo "== Step 3: workspace-repo volume genuinely shared (ADR-0003 Decision 1) =="

volume_marker="bulkhead-volume-check-$(date +%s)"
docker compose exec -T git-mcp sh -c "echo shared-ok > /repo/${volume_marker}" >/dev/null 2>&1
seen="$(docker compose exec -T workspace cat "/repo/${volume_marker}" 2>&1)"

if printf '%s' "$seen" | grep -q 'shared-ok'; then
  record step3.shared-volume pass "a file written by git-mcp into /repo is visible from workspace's /repo"
else
  record step3.shared-volume fail "a file written by git-mcp into /repo is visible from workspace's /repo" "$seen"
fi

# ---- Step 4: git-mcp responds correctly whether configured or not -------

echo
echo "== Step 4: git-mcp's status tool (configured vs. not-configured) =="

git_remote_configured="$(docker compose exec -T git-mcp printenv GIT_REMOTE_URL 2>/dev/null | tr -d '[:space:]')"

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

git_status_py="${mcp_client_common}
async def main():
    out = {}
    try:
        from mcp import ClientSession
        from mcp.client.streamable_http import streamablehttp_client
        async with streamablehttp_client('http://git-mcp:8805/mcp') as (read, write, _sid):
            async with ClientSession(read, write) as session:
                await session.initialize()
                result = await session.call_tool('status', {})
                text = '\n'.join((getattr(b, 'text', '') or '') for b in result.content)
                out['text'] = text
    except Exception as e:
        out['error'] = ' | '.join(_flatten(e))
    print(json.dumps(out))
asyncio.run(main())
"

status_result="$(docker compose exec -T orchestrator python3 -c "$git_status_py" 2>&1)"

if [ -n "$git_remote_configured" ]; then
  if printf '%s' "$status_result" | grep -q 'not configured'; then
    record step4.git-status-tool fail "git-mcp status tool reflects its configured state" \
      "GIT_REMOTE_URL is set but status still reports not-configured: $status_result"
  else
    record step4.git-status-tool pass "git-mcp status tool reflects its configured state" "$status_result"
  fi
else
  if printf '%s' "$status_result" | grep -q 'not configured'; then
    record step4.git-status-tool pass "git-mcp status tool reflects its configured state (unconfigured checkout)" "$status_result"
  else
    record step4.git-status-tool fail "git-mcp status tool reflects its configured state" \
      "GIT_REMOTE_URL is unset but status did not report not-configured: $status_result"
  fi
fi

# ---- Step 5: admin tools excluded from the Orchestrator's LLM config ----

echo
echo "== Step 5: push_execute/pending_push/push_cancel absent from orchestrator's LLM config (ADR-0003 Decision 3) =="

config_content="$(docker compose exec -T orchestrator cat /app/mcp_agent.config.yaml 2>&1)"
# Strip comments before matching - the file's own header comment explains
# *why* 8806/push_execute/pending_push/push_cancel are excluded, which
# means it contains those exact strings as prose. A raw grep across the
# whole file (comments included) flags that explanation as if it were a
# leak; check the functional YAML content only.
config_active="$(printf '%s\n' "$config_content" | sed 's/#.*//')"

if printf '%s' "$config_active" | grep -q '8805' \
  && ! printf '%s' "$config_active" | grep -qE '8806|push_execute|pending_push|push_cancel'; then
  record step5.admin-tools-excluded pass \
    "orchestrator's mcp_agent.config.yaml registers git-mcp's LLM port but never its admin port/tools"
else
  record step5.admin-tools-excluded fail \
    "orchestrator's mcp_agent.config.yaml registers git-mcp's LLM port but never its admin port/tools" \
    "$config_content"
fi

# ---- Step 6: MCP tool-surface allowlist ---------------------------------

echo
echo "== Step 6: MCP tool-surface allowlist, now covering git-mcp/git-mcp-admin =="

if allowlist_out="$(sh scripts/check-mcp-allowlist.sh 2>&1)"; then
  record step6.mcp-allowlist pass "all registered MCP servers' tool surfaces match the allowlist" "$allowlist_out"
else
  record step6.mcp-allowlist fail "all registered MCP servers' tool surfaces match the allowlist" "$allowlist_out"
fi

# ---- Steps 7-9: real git remote, opt-in ---------------------------------

echo
echo "== Steps 7-9: real git remote (opt-in on GIT_REMOTE_URL) =="

if [ -z "$git_remote_configured" ]; then
  skip step7.local-git-ops-through-chat "local git ops through the real chat/LLM path" "GIT_REMOTE_URL not set on git-mcp"
  skip step8.push-request-branch-rejected "push_request against a disallowed branch is rejected" "GIT_REMOTE_URL not set on git-mcp"
  skip step9.push-not-immediate "push_request stages without pushing" "GIT_REMOTE_URL not set on git-mcp"
  skip step9.deny-cancels-and-blocks-reapproval "deny cancels a pending push and blocks re-approval" "GIT_REMOTE_URL not set on git-mcp"
  skip step9.approve-pushes-to-remote "approve actually pushes to the remote" "GIT_REMOTE_URL not set on git-mcp"
elif [ -z "${token:-}" ]; then
  record step7.local-git-ops-through-chat fail "skipped - no chat-mcp token"
  record step8.push-request-branch-rejected fail "skipped - no chat-mcp token"
  record step9.push-not-immediate fail "skipped - no chat-mcp token"
  record step9.deny-cancels-and-blocks-reapproval fail "skipped - no chat-mcp token"
  record step9.approve-pushes-to-remote fail "skipped - no chat-mcp token"
else
  # A passphrase-protected deploy key that hasn't been unlocked yet (see
  # git-mcp/git-mcp-unlock/state.py's _start_agent) leaves git-mcp's repo
  # uncloned - step7/step9 would otherwise fail deep inside a real git/ssh
  # call with a cryptic "Permission denied (publickey)"/"Could not read
  # from remote repository" rather than the actual, fixable cause. Check
  # once up front and give one clear message for those instead. step8 is
  # unaffected either way - its disallowed-branch case is rejected before
  # ever touching git, so it always runs for real below.
  repo_ready=false
  docker compose exec -T git-mcp sh -c \
    '[ -d "${GIT_REPO_PATH:-/repo}/.git" ]' >/dev/null 2>&1 && repo_ready=true
  not_ready_msg="git-mcp's working tree isn't cloned yet - if its deploy key has a passphrase, run 'nix run .#git-unlock' (or 'nix run .#up') first, then re-run this script"
  send_chat() {
    curl -s -o /dev/null -X POST "http://localhost:8787/api/send?token=${token}" \
      -H 'Content-Type: application/json' -d "$(python3 -c 'import json,sys; print(json.dumps({"text": sys.argv[1]}))' "$1")"
  }

  # wait_for_reply <since-id> <grep-pattern> <max-tries> -> prints the
  # matching reply text (empty on timeout)
  wait_for_reply() {
    since="$1"; pattern="$2"; tries="${3:-30}"
    for _ in $(seq 1 "$tries"); do
      sleep 2
      msgs="$(curl -s "http://localhost:8787/api/messages?since=${since}&token=${token}")"
      match="$(printf '%s' "$msgs" | python3 -c "
import json, re, sys
data = json.load(sys.stdin)
pat = re.compile(sys.argv[1])
for m in data.get('messages', []):
    if m.get('role') != 'user' and pat.search(m.get('text') or ''):
        print(m['text'])
        break
" "$pattern" 2>/dev/null)"
      if [ -n "$match" ]; then
        printf '%s' "$match"
        return 0
      fi
    done
    return 1
  }

  last_id() {
    curl -s "http://localhost:8787/api/messages?since=0&token=${token}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(max((m['id'] for m in data.get('messages', [])), default=0))
" 2>/dev/null
  }

  # -- Step 7: local git ops through the real chat/LLM path ---------------

  echo
  echo "== Step 7: local git operations through the real chat/LLM path (ADR-0003 Decision 2) =="

  if ! $repo_ready; then
    record step7.local-git-ops-through-chat fail "$not_ready_msg"
  else
    git_marker="bulkhead-git-check-$(date +%s)"
    since="$(last_id)"
    send_chat "Using workspace_exec, write the text hello-from-validate-phase3 into a new file at /repo/${git_marker}.txt. Then call git_commit with the commit message 'validate-phase3: ${git_marker}'. Briefly confirm when done."
    wait_for_reply "$since" "${git_marker}" 40 >/dev/null

    # 60 tries * 2s = up to 120s here, on top of wait_for_reply's own 80s
    # above (whose result is discarded but which still consumes wall time
    # first) - confirmed live that the write-file-then-git_commit round
    # trip through a real chat/LLM turn can genuinely take longer than this
    # combined ~120s used to allow: two consecutive validate-phase3.sh runs
    # each recorded the marker commit as landing (visible in the *next*
    # run's `git log`), just after their own budget had already given up
    # and recorded a fail.
    log_output=""
    for _ in $(seq 1 60); do
      sleep 2
      log_output="$(docker compose exec -T git-mcp git -C /repo log --oneline -n 20 2>&1)"
      printf '%s' "$log_output" | grep -q "$git_marker" && break
    done

    if printf '%s' "$log_output" | grep -q "$git_marker"; then
      record step7.local-git-ops-through-chat pass \
        "agent wrote a file via workspace_exec and committed it via git_commit; commit found in git-mcp's log" "$log_output"
    else
      record step7.local-git-ops-through-chat fail \
        "agent wrote a file via workspace_exec and committed it via git_commit; commit found in git-mcp's log" "$log_output"
    fi
  fi

  # -- Step 8: push_request against a disallowed branch is rejected -------

  echo
  echo "== Step 8: push_request against a disallowed branch is rejected (ADR-0003 Decision 3/4) =="

  branch_pattern="$(docker compose exec -T git-mcp printenv GIT_PUSH_BRANCH_PATTERN 2>/dev/null | tr -d '[:space:]')"
  [ -n "$branch_pattern" ] || branch_pattern="agent/*"
  disallowed_branch="bulkhead-disallowed-$(date +%s)"

  actually_matches="$(python3 -c "
import fnmatch
print(fnmatch.fnmatch('${disallowed_branch}', '${branch_pattern}'))
")"

  if [ "$actually_matches" = "True" ]; then
    skip step8.push-request-branch-rejected \
      "push_request against a disallowed branch is rejected" \
      "GIT_PUSH_BRANCH_PATTERN ('${branch_pattern}') matches '${disallowed_branch}' too - can't construct a disallowed branch name generically"
  else
    since="$(last_id)"
    send_chat "Call git_push_request with branch '${disallowed_branch}' - I want to see what happens, don't ask me first."
    wait_for_reply "$since" "." 30 >/dev/null

    pending_after="$(docker compose exec -T orchestrator python3 -c "$mcp_client_common
async def main():
    out = {}
    try:
        from mcp import ClientSession
        from mcp.client.streamable_http import streamablehttp_client
        async with streamablehttp_client('http://git-mcp:8806/mcp') as (read, write, _sid):
            async with ClientSession(read, write) as session:
                await session.initialize()
                result = await session.call_tool('pending_push', {})
                text = '\n'.join((getattr(b, 'text', '') or '') for b in result.content)
                out['text'] = text
    except Exception as e:
        out['error'] = ' | '.join(_flatten(e))
    print(json.dumps(out))
asyncio.run(main())
" 2>&1)"

    if printf '%s' "$pending_after" | grep -q "$disallowed_branch"; then
      record step8.push-request-branch-rejected fail \
        "push_request against a disallowed branch is rejected" \
        "disallowed branch '${disallowed_branch}' appears in pending_push: $pending_after"
    else
      record step8.push-request-branch-rejected pass \
        "push_request against a disallowed branch is rejected" "$pending_after"
    fi
  fi

  # -- Step 9: push_request / approve / deny round-trip against the real
  #    remote --------------------------------------------------------------

  echo
  echo "== Step 9: push_request / approve / deny round-trip against the real remote (ADR-0003 Decision 3) =="

  if ! $repo_ready; then
    record step9.push-not-immediate fail "$not_ready_msg"
    record step9.deny-cancels-and-blocks-reapproval fail "$not_ready_msg"
    record step9.approve-pushes-to-remote fail "$not_ready_msg"
  else

  extract_request_id() {
    # extract_request_id <reply-text> <branch> - pulls the request_id out of
    # main.py's own "reply 'approve <id>'" notice for the given branch line.
    printf '%s' "$1" | grep -oE "[0-9a-f]{16}: push HEAD -> [^ ]*/${2} " | grep -oE '^[0-9a-f]{16}' | head -1
  }

  ls_remote() {
    # Keep 2>&1 (not 2>/dev/null) so a genuine ssh/auth failure still shows
    # up in this output for debugging - but filter out the one-time
    # "Warning: Permanently added ... to the list of known hosts." line a
    # fresh git-mcp container prints to stderr on its *first* connection to
    # the remote (StrictHostKeyChecking=accept-new). Confirmed live: with
    # 2>&1 unfiltered, that single benign line made the very first
    # ls_remote call of a run look non-empty - i.e. "branch already exists"
    # - even though the actual ls-remote output (and the branch) was empty.
    #
    # Match on the distinctive phrase only, no ^/$ anchors - confirmed live
    # that a fully-anchored pattern still let this line through even though
    # it looked byte-for-byte identical on screen (docker compose exec -T's
    # pty-less stream may carry a trailing \r or similar that isn't visibly
    # obvious but breaks a strict end-of-line anchor). "Permanently added
    # ... to the list of known hosts" is ssh's own fixed wording - specific
    # enough that a loose match still can't collide with real ls-remote
    # output (refs/sha1 lines never contain this phrase).
    docker compose exec -T git-mcp git -C /repo ls-remote origin "refs/heads/$1" 2>&1 \
      | grep -v 'Permanently added.*to the list of known hosts'
  }

  deny_branch="agent/bulkhead-validate-deny-$(date +%s)"
  since="$(last_id)"
  send_chat "Call git_push_request with branch '${deny_branch}'."
  reply="$(wait_for_reply "$since" "approve" 30)"
  deny_id="$(extract_request_id "$reply" "$deny_branch")"

  if [ -z "$deny_id" ]; then
    record step9.push-not-immediate fail "push_request stages without pushing" \
      "could not extract a request_id from the agent's reply: $reply"
    record step9.deny-cancels-and-blocks-reapproval fail "deny cancels a pending push and blocks re-approval" \
      "no request_id to work with"
  else
    remote_before="$(ls_remote "$deny_branch")"
    if [ -n "$remote_before" ]; then
      record step9.push-not-immediate fail "push_request stages without pushing" \
        "remote already has refs/heads/${deny_branch} right after push_request: $remote_before"
    else
      record step9.push-not-immediate pass "push_request stages without pushing" \
        "refs/heads/${deny_branch} absent on the remote immediately after push_request"
    fi

    since="$(last_id)"
    send_chat "deny ${deny_id}"
    wait_for_reply "$since" "." 15 >/dev/null
    remote_after_deny="$(ls_remote "$deny_branch")"

    since="$(last_id)"
    send_chat "approve ${deny_id}"
    reapprove_reply="$(wait_for_reply "$since" "." 15)"

    if [ -n "$remote_after_deny" ]; then
      record step9.deny-cancels-and-blocks-reapproval fail "deny cancels a pending push and blocks re-approval" \
        "remote unexpectedly has refs/heads/${deny_branch} after deny: $remote_after_deny"
    elif printf '%s' "$reapprove_reply" | grep -qiE 'no pending push'; then
      record step9.deny-cancels-and-blocks-reapproval pass "deny cancels a pending push and blocks re-approval" \
        "remote still absent after deny, and approving the same id afterward was rejected: $reapprove_reply"
    else
      record step9.deny-cancels-and-blocks-reapproval fail "deny cancels a pending push and blocks re-approval" \
        "remote still absent after deny, but approving the same id afterward wasn't rejected as expected: $reapprove_reply"
    fi
  fi

  approve_branch="agent/bulkhead-validate-approve-$(date +%s)"
  since="$(last_id)"
  send_chat "Call git_push_request with branch '${approve_branch}'."
  reply="$(wait_for_reply "$since" "approve" 30)"
  approve_id="$(extract_request_id "$reply" "$approve_branch")"

  if [ -z "$approve_id" ]; then
    record step9.approve-pushes-to-remote fail "approve actually pushes to the remote" \
      "could not extract a request_id from the agent's reply: $reply"
  else
    since="$(last_id)"
    send_chat "approve ${approve_id}"
    wait_for_reply "$since" "." 30 >/dev/null
    remote_after_approve="$(ls_remote "$approve_branch")"

    if printf '%s' "$remote_after_approve" | grep -q "refs/heads/${approve_branch}"; then
      record step9.approve-pushes-to-remote pass "approve actually pushes to the remote" "$remote_after_approve"
    else
      record step9.approve-pushes-to-remote fail "approve actually pushes to the remote" \
        "refs/heads/${approve_branch} not found on remote after approve: $remote_after_approve"
    fi
  fi
  fi
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
