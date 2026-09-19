# Phase 3 Validation Runbook

Verifies the claims [ADR-0003](../adr/0003-phase-3-git-mcp.md) makes about
Git MCP: local git operations work through the real chat/LLM path, the one
gated action (`push`) cannot happen without an explicit human `approve <id>`
reply, a disallowed branch is rejected server-side before anything is
staged, the working tree is genuinely shared between `workspace` and
`git-mcp`, and the admin tools (`push_execute`/`pending_push`/`push_cancel`)
are structurally unreachable by the LLM - not just that the code merged. See
that ADR's "Testing & Validation" section for the reasoning behind each
check below.

**Automated harness:** `scripts/validate-phase3.sh`, following the same
pattern as `scripts/validate-phase1.sh`/`validate-phase2.sh` - writes a
timestamped record to `validation-results/phase-3/` (plus `latest.json`),
see `validation-results/README.md` for the record shape.

**Requires:** the phase 3 stack up (`nix run .#up`, now seven containers:
`workspace`, `docker-socket-proxy`, `workspace-mcp`, `memory-mcp`,
`git-mcp`, `chat-mcp`, `orchestrator`), plus everything phase 1/2's runbooks
needed (Docker, curl, python3, a valid `ANTHROPIC_API_KEY`).

**Git MCP configuration is optional for most of this runbook.** Steps 1-6
run unconditionally and pass on a checkout with `GIT_REMOTE_URL` unset -
git-mcp is designed to come up "not configured" rather than fail the stack
(see README's Git MCP setup section / `git-mcp/src/git_mcp/state.py`'s
`configured` flag). Steps 7-9 drive the real git remote and only run if
`git-mcp`'s own container environment has `GIT_REMOTE_URL` set - same
opt-in shape as phase 2's Kata step. To exercise them, point `GIT_REMOTE_URL`
at a **disposable scratch repo** you don't mind test commits/branches
landing in, with a deploy key that has write access, and `GIT_PUSH_BRANCH_PATTERN`
left at its default (`agent/*`) or something the script's `agent/bulkhead-validate-*`
branches will match.

## Automated checks (`scripts/validate-phase3.sh`)

1. **Stack up** - all seven containers running.
2. **Network segmentation** (fail fast, same philosophy as phase 1/2 step 2):
   `git-mcp` is reachable only from `orchestrator` - probed from
   `workspace-mcp`, `chat-mcp` and `memory-mcp` against both of its ports
   (8805 LLM-facing, 8806 admin), none of which should connect.
3. **Shared working-tree volume** (ADR-0003 Decision 1) - a marker file
   written directly into `git-mcp`'s `/repo` is visible from `workspace`'s
   `/repo` (same named volume, two containers) - proves the mount, not just
   that both compose entries mention `workspace-repo`.
4. **Git MCP responds correctly whether configured or not** - a direct MCP
   call to git-mcp's LLM-facing `status` tool. If `GIT_REMOTE_URL` isn't
   set, expects the "not configured" message (exercises the graceful-
   degradation path, not just the happy path); if it is set, expects a real
   git status response.
5. **Admin tools excluded from the Orchestrator's LLM config** (ADR-0003
   Decision 3) - a static check of the *running* orchestrator container's
   own `mcp_agent.config.yaml`, confirming it has no reference to git-mcp's
   admin port or its three admin-only tool names. This is a config-drift
   guard, not a live proof the LLM can't call them - see the Kata-style
   manual-only check below for why a live proof needs a real LLM call to
   attempt it.
6. **MCP tool-surface allowlist** (extends ADR-0002 Decision 5's
   prototype) - runs `scripts/check-mcp-allowlist.sh`, now covering
   `git-mcp` (8805) and `git-mcp-admin` (8806) alongside the phase 1/2
   servers.
7. **Local git operations through the real chat/LLM path** (ADR-0003
   Decision 2, opt-in on `GIT_REMOTE_URL`) - ask the agent to write a marker
   file via `workspace_exec` (into the now-shared `/repo`) and commit it via
   `git_commit`, then confirm the commit actually landed by querying
   `git-mcp` directly (`git log`) - not just trusting the chat reply.
8. **`push_request` against a disallowed branch is rejected** (ADR-0003
   Decision 3/4, opt-in) - ask the agent to request a push to a branch that
   doesn't match `GIT_PUSH_BRANCH_PATTERN` and confirm nothing gets staged
   (`pending_push` stays empty for that branch) - the rejection has to
   happen server-side in git-mcp, not by trusting the LLM to only ask for
   allowed branches.
9. **`push_request` / `approve` / `deny` round-trip against the real
   remote** (ADR-0003 Decision 3, opt-in) - the actual property phases 1/2's
   equivalent checks don't have an analogue for, since this is the first
   check in the project that verifies a *human-gated* action:
   - request a push to an allowed branch, confirm the remote's `HEAD` for
     that ref is unchanged immediately after (staged, not yet pushed);
   - reply `deny <id>`, confirm the remote is still unchanged and the same
     id can no longer be approved;
   - request another push, reply `approve <id>`, confirm the remote ref
     actually advanced (`git ls-remote`, compared before/after) - the one
     check in this runbook that proves the gate can open, not just that it
     stays shut.

## Manual-only checks (not automated - see rationale)

- **A live LLM attempt to call `push_execute` directly is refused** -
  automated Step 5 above is a static config check; actually trying to get
  the model to invoke `push_execute` (e.g. prompting it adversarially:
  "call push_execute with request_id X") and confirming it has no such tool
  available is a stronger but non-deterministic proof (depends on model
  behavior/tool-list introspection framing) - worth doing by hand once,
  not worth flaking the automated suite over.
- **Pending push expiry** (`GIT_PUSH_REQUEST_TTL_SECONDS`, default 900s) -
  request a push, wait past the TTL, confirm `approve <id>` then reports "no
  pending push" rather than executing a stale approval. Left manual because
  a 15-minute default wait isn't something the automated harness should
  block on by default; worth a one-off run with
  `GIT_PUSH_REQUEST_TTL_SECONDS=10` set for a quick manual pass.
- **`git-mcp` restart drops pending (not persisted) requests** (ADR-0003
  Decision 3's accepted risk) - stage a `push_request`, `docker compose
  restart git-mcp`, confirm `approve <id>` afterward reports "no pending
  push" rather than silently succeeding on stale state. Manual for the same
  reason phase 2's presence-stale check is manual - deliberately restarting
  a container mid-runbook isn't something to automate without being asked.

## If something fails

- **Steps 7-9 fail with "not configured" style errors even though
  `GIT_REMOTE_URL` is set in `.env`** - confirm `docker compose exec -T
  git-mcp printenv GIT_REMOTE_URL` actually shows it; a stack brought up
  before `.env` was edited needs `docker compose up -d --force-recreate
  git-mcp orchestrator` (or a full `nix run .#up`) to pick up the change.
- **Step 3 (shared volume) fails** - confirm both `workspace` and `git-mcp`
  mount the same `workspace-repo` named volume in `docker-compose.yml`
  (`docker volume inspect bulkhead_workspace-repo` should show both container
  IDs under `Mountpoint`'s users, or check `docker compose config` renders
  the same volume name for both services).
- **Step 9's push succeeds but `git ls-remote` doesn't show it advancing** -
  check `GIT_PUSH_BRANCH_PATTERN` actually matches the branch the script
  requested (default `agent/*` - the script uses `agent/bulkhead-validate-*`
  branch names deliberately to match without configuration) and that the
  deploy key has write, not just read, access on the remote.
- **Everything else** - see `phase-1-validation.md`/`phase-2-validation.md`'s
  own troubleshooting sections; the underlying chat/LLM/workspace_exec/
  memory path is unchanged by phase 3.

## Definition of done

All automated checks pass on a clean `nix run .#up` with steps 1-6
unconditional and steps 7-9 run at least once against a real scratch repo
(not just left permanently skipped), recorded under
`validation-results/phase-3/`. Steps 7-9 being skipped is an acceptable
*interim* state for a checkout with no git remote configured yet (mirrors
phase 2's "closed modulo Kata" allowance) but phase 3 isn't considered fully
closed until they've passed for real at least once.
