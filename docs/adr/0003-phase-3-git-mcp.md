# ADR-0003: Phase 3 — Git MCP (Code Egress)

- Status: Amended by [ADR-0004](0004-git-mcp-bundle-relay.md) - Decisions 1
  and 2 below (the shared working-tree volume, and local git tools living in
  git-mcp) are superseded; Decisions 3, 4 and 5 (push_request/push_execute,
  the deploy key, network segmentation) are unchanged and still current.
- Date: 2026-09-19
- Supersedes: none
- Amends: none (additive - see Decision 1 for the one previously-open README
  point this resolves)
- Related: [phase-3-scope.md](../plans/phase-3-scope.md),
  [README.md](../../README.md) (Egress section, cornerstone 9),
  [ADR-0001](0001-phase-1-four-container-architecture.md),
  [ADR-0002](0002-phase-2-isolation-ux-memory.md)

## Context

README's Egress section names Git MCP as one of exactly two approved paths
for data to leave the Workspace Sandbox, and scopes it tightly: local git
operations (commit, branch, diff, log) are ungated, since they never cross
the network-isolation boundary; the one operation that does cross it - push
to a pre-configured remote - requires human approval, holds its own
credentials, and accepts no arbitrary remotes, no force-push, no git config
changes, no hooks. Both ADR-0001 and ADR-0002 deferred building this to a
later phase; [phase-3-scope.md](../plans/phase-3-scope.md) is that phase.

Building this surfaced one question README left genuinely open (point 8):
where does the Workspace's actual working tree live? Today it doesn't live
anywhere - the Workspace container has no working-tree volume at all, only
whatever `implementation.md`'s v1 image bakes in. Git MCP can't do local git
work on the agent's behalf without an answer to this, so this ADR resolves
it as part of the same decision rather than treating it as a separate,
smaller question.

## Decision

### 1. Working tree: a shared named volume, not a host bind mount

A new Docker-managed named volume (`workspace-repo`) is mounted into both
`workspace` and the new `git-mcp` container, at the same path in each
(`/repo`). This is README point 8's second option ("separate workspace in
the container, syncing to an external server via the Git MCP"), not the
first (host bind mount).

**Why not a host bind mount**: every other piece of persistent state in this
project's topology so far (`memory-data`) is a Docker-managed volume, not a
host path - keeping the working tree the same way means the host filesystem
never becomes part of the container topology's trust boundary. A bind mount
would also make the Workspace's contents trivially inspectable/editable from
the host outside Bulkhead's own containment model, which cuts against the whole
point of the project.

**Consequence for Workspace MCP's `exec` tool**: no change to its tool
surface - `command` still runs via `docker exec` against the `workspace`
container, which now simply has `/repo` populated. Workspace still does not
need `git` installed (confirmed, not just asserted, by this design): all git
operations are done by `git-mcp` acting on the same volume from its side,
not by anything shelled out to inside `workspace`.

`git-mcp` populates the volume on first start: if `/repo` is empty, clone
`GIT_REMOTE_URL`; if it already contains a `.git` directory (a prior
session's volume, not recreated), skip the clone. This is the "syncing"
README point 8 names.

### 2. Git MCP container - local operations, given directly to the LLM

New container, `git-mcp`, Python + `git` CLI (same Dockerfile shape as
Workspace MCP - `python:3.12-slim` plus one apt package, per-image Nix
build via `nix run .#build-git-mcp-image`, matching ADR-0001 §3's pattern
for the non-pure-Nix Python containers).

Tools, all operating on the shared volume via `git -C /repo ...`, registered
as a normal MCP server (`server_names=[..., "git"]` on the Orchestrator's
`Agent`, alongside `workspace`/`memory` - mcp-agent namespaces these as
`git_status`, `git_diff`, etc.):

- `status()`, `diff(path: str | None, rev_range: str | None = None)`,
  `log(limit: int = 20, path: str | None = None, stat: bool = False)`,
  `branch_list(contains: str | None = None)`,
  `show(rev: str, path: str | None)`, `remote()`, `rev_parse(rev: str)`,
  `merge_base(rev_a: str, rev_b: str)`, `tag_list()` - read-only.
- `commit(message: str)`, `create_branch(name: str)`, `checkout(name: str)` -
  local writes (`checkout` also picks up a not-yet-local remote-tracking
  branch via git's own DWIM, once `fetch` below has brought it down).

All of these except `fetch` match README's explicit carve-out ("isn't gated
- the Workspace Sandbox is already fully network isolated") - the same
reasoning applies unchanged: `git-mcp` itself has no inbound path from
anywhere except the Orchestrator, so these tools crossing *into* `git-mcp`
isn't a new egress path.

**`fetch()` - added later, the one deliberate exception.** Unlike everything
else above, `fetch` does cross the network boundary: it updates
remote-tracking refs (e.g. `origin/main`) from the pre-configured remote,
the same one `push_request`/`push_execute` already reach. Given directly to
the LLM, not gated like push, because it's read-only against the remote
(nothing is sent, only received), it can only ever target the one
already-configured remote (no arbitrary URL, no adding a new remote), and it
makes no local mutation beyond updating `refs/remotes/*` - the working tree
and local branches are untouched. The one risk this doesn't cover - a
compromised or hostile remote serving malicious ref content back - is a risk
`push_execute` already accepts implicitly by trusting the pre-configured
remote at all; `fetch` doesn't introduce a new one.

### 3. The one gated action - `push_request` / `push_execute` split

This is the ADR-worthy decision, not the read-only tools above: it's a new
instance of README cornerstone 9's human-approval-gate pattern, and the
project doesn't yet have a generic mechanism for "LLM proposes, human
approves, harness executes" - only the narrower precedent of keeping an
entire tool *permanently* off the LLM's list (`chat_send`/`chat_receive`,
ADR-0001 §2).

**Mechanism**: two tools, split across the LLM/harness boundary the same way
Chat MCP already splits `chat_send` (harness-only) from `workspace_exec`
(LLM-callable):

- `push_request(branch: str) -> {request_id, branch, remote}` - **LLM-
  callable** (part of the `git` server's tool set). Validates `branch`
  against `GIT_PUSH_BRANCH_PATTERN` (a fixed glob/regex from config, e.g.
  `agent/*` - enforced server-side in `git-mcp`, not trusted from the
  caller) and the remote against the single pre-configured `GIT_REMOTE_URL`.
  Stages the request in memory (deliberately not persisted - see
  Consequences) and returns a `request_id`. Does **not** push. Rejects
  anything outside the branch pattern before staging anything.
- `push_execute(request_id: str) -> {stdout, stderr, exit_code}` -
  **harness-only, never given to the LLM** (not in `server_names`'s tool
  list; called directly by the Orchestrator's harness code via a small
  hand-rolled client, the same shape as `chat_client.py`). Runs
  `git -C /repo push <remote> HEAD:<branch>` using the deploy key
  (Decision 4), only for a `request_id` that matches a currently-pending,
  unexpired request.

**Approval flow (harness-level, `orchestrator/main.py`'s loop)**: after each
`llm.generate_str()` call, the harness checks `git-mcp` for a pending
request (a new harness-only `pending_push()` tool, same LLM-exclusion as
`push_execute`). If one exists, the harness's own message to the human
(via `chat.send`, not the LLM's reply) appends an explicit approval prompt
naming the `request_id`, remote, and branch. The harness then treats the
*next* human chat message as a command it parses itself - not something
handed to the LLM - matching exactly one of two forms
(`approve <request_id>` / `deny <request_id>`); anything else is passed
through to the LLM as a normal message and the pending request stays
pending. On `approve`, the harness calls `push_execute` directly and reports
the result to the human via `chat.send`; on `deny`, it calls a
`push_cancel(request_id)` tool (also harness-only) and confirms cancellation.

This keeps the actual network-crossing operation entirely outside the LLM's
reachable tool surface, structurally, not just by prompt instruction - the
same guarantee ADR-0001 §2 relies on for `chat_send`/`chat_receive`.

**Implementation mechanism**: `server_names` attaches a *whole* MCP server's
tool list to the LLM - mcp-agent has no per-tool filter, which is exactly
why ADR-0001 §2 kept Chat MCP off `server_names` entirely rather than trying
to expose only some of its tools. `git-mcp` reuses that same whole-server
split, applied *within* one container instead of across two: it runs two
separate `MCPServer` instances on two ports in one process (the same shape
Chat MCP already uses for its MCP port + web UI port - see
`chat-mcp/src/chat_mcp/server.py`'s `asyncio.gather`), both closing over one
shared in-process `GitState` (the pending-request store and repo config):
- port 8805 - the LLM-facing server (`status`/`diff`/`log`/`branch_list`/
  `commit`/`create_branch`/`checkout`/`push_request`/`show`/`remote`/
  `rev_parse`/`merge_base`/`tag_list`/`fetch`), registered in
  `mcp_agent.config.yaml` and attached via `server_names`. All but `fetch`
  and `push_request` are local-only; see the `fetch` follow-up note below
  for why that one's network reach is still within this ADR's boundary.
- port 8806 - the harness-only admin server (`pending_push`/`push_execute`/
  `push_cancel`), **never** registered in `mcp_agent.config.yaml` or
  `server_names` - reached only by a new hand-rolled `GitAdminClient` in the
  Orchestrator (`orchestrator/src/orchestrator/git_admin_client.py`, same
  shape as `chat_client.py`), called directly from `main.py`'s harness loop.

### 4. Credentials - SSH deploy key, held only by `git-mcp`

A deploy key scoped to the single configured remote/repo, read-only
bind-mounted into `git-mcp` alone (never the shared volume, never any other
container). `git-mcp` sets `GIT_SSH_COMMAND` to point at it
(`ssh -i /run/secrets/deploy_key -o IdentitiesOnly=yes`) for the one `git
push` invocation `push_execute` makes. No other container in the topology
gets any credential capable of reaching the remote - matches README's
"Holds the auth credentials itself so the Workspace Sandbox/Agent never see
them."

**Why a deploy key over a PAT**: a deploy key is scoped to one repo by the
remote host itself (GitHub/GitLab-enforced), which is a stronger, externally-
enforced version of the same narrowing `GIT_PUSH_BRANCH_PATTERN` does in
`git-mcp`'s own code - defense in depth against a bug in that pattern check,
not just a config-file preference.

**No arbitrary remotes / no force-push / no config changes / no hooks**, all
enforced by construction rather than convention:
- `push_execute` hardcodes the remote name/URL from `GIT_REMOTE_URL`; no
  tool accepts a remote parameter.
- No tool exposes `--force` or any flag beyond what `push_execute` itself
  passes.
- No tool wraps `git config` or `git remote add/set-url` at all - not just
  ungated-but-present, genuinely absent from the tool surface.
- The image ships with `core.hooksPath` pointed at an empty, non-writable
  directory (or hooks stripped from the cloned repo on init) so a hook
  committed upstream can't execute inside `git-mcp` on checkout/push.

### 5. Network segmentation - `internal-git` plus a scoped `git-egress`

Two networks, mirroring how Memory MCP was split in ADR-0002 §4/§5:

- `internal-git` (`internal: true`) - joined only by `git-mcp` and
  `orchestrator`, for the MCP tool traffic. Not shared with
  `internal-workspace`/`internal-chat`/`internal-memory`/
  `internal-docker-proxy` - same reasoning each of those splits already
  established: two servers on one shared internal network can reach each
  other directly, which none of them should be able to do.
- `git-egress` (not internal) - joined only by `git-mcp`, for the one
  outbound connection `push_execute` makes to the git remote (SSH, typically
  port 22 or GitHub's 443 fallback). Deliberately **not** the Orchestrator's
  existing `egress` network: the Orchestrator has no business reaching the
  git remote directly, and `git-mcp` has no business reaching the LLM
  provider - least privilege in both directions, not just one.

## Testing & Validation

Written up as [phase-3-validation.md](../plans/phase-3-validation.md) and
`scripts/validate-phase3.sh`, following the phase 1/2 pattern. Headline
properties that runbook independently verifies (per Stuart's phase-2-style
requirement: verify the capability, not just that code merged):

- Local git ops (`status`/`diff`/`log`/`commit`/`branch`) work end-to-end
  through the real chat/LLM path against the shared volume.
- `push_request` against a branch outside `GIT_PUSH_BRANCH_PATTERN` is
  rejected server-side, before staging anything.
- A pending `push_request` is **not** pushed without an explicit
  `approve <id>` human chat message - confirm the remote's HEAD is unchanged
  after `push_request` alone.
- `approve <id>` actually pushes (remote HEAD advances); `deny <id>`
  cancels and a subsequent `approve <id>` on the same, now-cancelled id is
  rejected.
- Network segmentation: `orchestrator` cannot reach `git-mcp`'s filesystem
  or the remote directly (only through `git-mcp`'s MCP tools); `git-mcp`
  cannot reach `chat-mcp`/`workspace-mcp`/`memory-mcp`; `workspace` still
  has no network of its own even though it now shares a volume with
  `git-mcp`.
- `push_execute` and `pending_push`/`push_cancel` are absent from the tool
  list the LLM actually receives (mirrors phase 2's `step9.mcp-allowlist`
  check).

## Consequences

**Positive**
- Resolves README point 8, which phases 1 and 2 both left open, as a
  side effect of doing this properly rather than as separately-scheduled
  work.
- The `push_request`/`push_execute` split gives Bulkhead a reusable pattern for
  "LLM proposes, human approves, harness executes" - the next gated action
  (artifact egress, per README's Egress item 2) can reuse this shape rather
  than inventing its own.
- No new credential exposure to the Workspace or the Orchestrator - the
  deploy key's blast radius is contained to exactly the one container that
  needs it.

**Negative / accepted risk**
- The pending-request store is in-memory in `git-mcp`, so a `git-mcp`
  restart silently drops any request awaiting approval (the human would see
  no response to `approve <id>` and have to re-trigger `push_request`).
  Accepted for phase 3 - persisting *pending, unapproved* actions durably is
  arguably worse (a stale approval surviving a restart and firing later,
  unexpectedly) than losing it and requiring a fresh request.
- The harness now parses two more freeform-adjacent human commands
  (`approve`/`deny <id>`) outside the LLM - a second piece of hand-rolled
  parsing logic alongside `chat_client.py`, worth keeping deliberately
  minimal (exact-match on two verbs plus an id) rather than growing into a
  general command grammar.
- `git-mcp` is now a container holding both real credentials (the deploy
  key) and real network egress to an external service - a distinct risk
  category from every other MCP server in the topology so far (Workspace
  MCP holds no credentials at all; Memory/Chat MCP hold no credentials and
  have no egress). Mitigated by Decision 4's defense-in-depth (scoped deploy
  key + branch-pattern check + no hooks), but worth naming as the highest-
  value target in the topology for an attacker, going forward.

**Follow-ups tracked for later phases**
- Artifact egress (`docker cp`, README Egress item 2), reusing this ADR's
  request/execute/approve pattern.
- Kata for `git-mcp`, once real usage validates the Workspace Kata migration
  further (phase-3-scope.md's "explicitly out of scope").
- Persisting/auditing approved-and-executed pushes (not pending ones) for a
  human-reviewable log - not required for phase 3, but a natural extension
  once the memory-store-poisoning mitigation (ADR-0002 §4's deferred
  pre-persistence review) is designed, since both are "show the human what's
  about to become permanent" problems.

## Alternatives Considered

- **Host bind mount for the working tree instead of a named volume.**
  Rejected - see Decision 1; breaks the project's established pattern of
  keeping all persistent state Docker-managed rather than host-visible.
- **Let the LLM call `push` directly, relying on the branch-pattern check
  alone (no human approval step).** Rejected outright - README's Egress
  section is explicit that push requires human approval; a server-side
  branch check mitigates a *misconfigured* push, not a deliberately or
  injection-triggered malicious one within an allowed branch pattern
  (README's "Further Threats" item 1, confused deputy via approved
  channels).
- **A broader PAT instead of a deploy key.** Rejected - a deploy key's
  repo-scoping is enforced by the remote host itself, strictly narrower than
  a PAT scoped by convention/documentation alone.
- **Reuse the Orchestrator's existing `egress` network for `git-mcp`'s
  outbound connection, instead of a new `git-egress` network.** Rejected -
  would give the Orchestrator an incidental route to `git-mcp`'s egress
  path's network segment and blur two independently-scoped egress reasons
  (LLM API vs. git remote) onto one network, contrary to every other
  network split this project has made so far.
- **Persist pending push requests to survive a `git-mcp` restart.**
  Considered and rejected for phase 3 - see Consequences; a lost pending
  request is a worse failure mode to avoid than a stale one silently
  surviving and later executing unexpectedly.
