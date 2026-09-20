# ADR-0004: Git MCP as a Bundle-Relay Auth Proxy

- Status: Accepted
- Date: 2026-09-20
- Supersedes: none
- Amends: [ADR-0003](0003-phase-3-git-mcp.md) - Decisions 1 and 2 (the shared
  working-tree volume, and where local git tools live) are replaced;
  Decisions 3, 4 and 5 (the push_request/push_execute split, the deploy key,
  and the network segmentation) are unchanged.
- Related: [README.md](../../README.md) (Egress section, cornerstone 9),
  [ADR-0001](0001-phase-1-four-container-architecture.md),
  [ADR-0002](0002-phase-2-isolation-ux-memory.md)

## Context

ADR-0003 gave `workspace` and `git-mcp` a shared named volume as the
project's working tree, with `git-mcp` doing every git operation - local and
remote - directly against it. That shared volume includes `.git/` itself:
its `config` and (absent the hooksPath override ADR-0003 Decision 4 sets at
clone time) its `hooks/` directory. Both are plain files inside a volume the
Workspace can write to.

That's a live vector, not a theoretical one: from `workspace_exec`, with no
git binary and no network needed, an agent can append
`core.hooksPath = /some/writable/dir` to `.git/config` and drop a script
there. The next ordinary, ungated LLM tool call that touches git in
`git-mcp` - `git_commit` via `core.hooksPath`'s `pre-commit`, `git_status`
via `core.fsmonitor`, `git_fetch` via `core.sshCommand` - runs that script
**inside `git-mcp`**, as the container holding the deploy key, the loaded
ssh-agent, and the only network path to the remote. That single step
defeats the branch-pattern check, the no-force-push rule, and the human
approval gate at once, because none of them run first - the hook fires
before `push_request`/`push_execute` are ever reached, from a tool call the
LLM can already make unsupervised.

The root cause isn't a missing check on that one config key - git has no
general "don't trust hooks from an untrusted checkout" mode, because it
isn't designed to run against a checkout an adversary can write to at all.
The fix has to be architectural: never let the untrusted side write anything
`git-mcp` reads as configuration.

## Decision

### 1. Git-mcp holds a private bare mirror, not a shared working tree

`git-mcp` mounts its own volume (`git-gateway-data`, at `GIT_GATEWAY_PATH`,
default `/gitdir`) - a `git clone --mirror` of the remote. No work tree, and
mounted nowhere else. This removes the vector at its root rather than
patching each config key: a bare repo has no checkout, so the
checkout-triggered hooks/filters (`smudge`/`clean`/`textconv`) can't fire
regardless of config, and nothing the Workspace writes anywhere is ever on a
path `git-mcp` reads.

As defense in depth, in case that assumption is ever violated by a future
change, every git invocation against the gateway also forces the remaining
config-driven-execution knobs off at `-c` precedence (beats any on-disk
value): `core.hooksPath=/dev/null`, `core.fsmonitor=`, `core.pager=cat`,
`core.askPass=`, `credential.helper=` (see `state.py`'s `HARDENED_GIT_ARGS`),
plus `GIT_CONFIG_NOSYSTEM`/`GIT_CONFIG_GLOBAL=/dev/null` so no ambient
config outside the gateway's own is ever consulted either.

### 2. Local git ops move to the Workspace; hooks run there, contained

`git` is now installed in the Workspace image (`workspace/default.nix`).
`status`/`diff`/`log`/`commit`/`branch`/`checkout`/etc. are no longer
`git-mcp` tools at all - the LLM runs them via `workspace_exec`, like any
other command, against the Workspace's own `/repo` (unchanged volume,
now exclusive to `workspace`).

This is a restoration, not just a relocation: ADR-0003 Decision 4 had to
disable hooks entirely (`core.hooksPath` pointed at an empty directory)
specifically because running them where the key lives was dangerous. Once
git execution happens in the Workspace instead - already the fully
network-isolated, disposable, Kata-contained side of the boundary, and the
one place cornerstone 7 says arbitrary tooling belongs - hooks can be left
fully enabled. A malicious `pre-commit` is just another contained command,
identical in blast radius to anything else `workspace_exec` runs. It has
nowhere to send anything and no credential to reach for.

`git-mcp`'s own LLM-facing surface shrinks to exactly two tools -
`fetch()` and `push_request(branch)` - the "auth proxy" shape: pull from the
remote, and stage a gated push to it. Nothing in that surface accepts a
config value, a hook, a remote, or a `--force` - narrowest-vocabulary
(cornerstone 9) applied to the git tool surface itself, not just to
individual parameters.

### 3. Syncing the two repos: a `git bundle` relay through the Orchestrator

The Workspace's commits and the gateway's copy of the remote now live in two
separate repos with no path between them - `workspace` has no network
(unchanged, and deliberately not widened for this), and `git-mcp` has no
network route to `workspace-mcp` (see Alternatives Considered below for why
that was rejected too). `git bundle` solves this without either: it's a
single inert file containing objects + refs, designed for exactly this
"exchange history with no live connection" case. Critically, importing one
(`git fetch <bundle-file> <refspec>` / `git bundle unbundle`) is a plain
fetch, not `receive-pack` - it never runs the receiving repo's hooks, so a
bundle can't carry an implicit code-execution step either.

Mechanism, mirroring the `push_execute`/admin-port split ADR-0003 Decision 3
already established:

- `workspace-mcp` splits into two ports, the same shape `git-mcp` already
  uses. LLM port (8801): `exec`, unchanged. Admin port (new, 8807):
  `export_bundle(refspec)` (runs `git bundle create - <refspec>` inside the
  Workspace) and `import_bundle(data_b64, refspec)` (writes a bundle to a
  temp file inside the Workspace and `git fetch`es it in). Bytes travel as
  base64 to stay JSON/text-safe over MCP. Neither tool is registered in
  `mcp_agent.config.yaml`/`server_names` - same exclusion as `git-mcp`'s
  admin port.
- `git-mcp`'s admin port gains the mirror pair (`export_bundle`/
  `import_bundle`), operating on the gateway.
- The Orchestrator's harness (`bundle_sync.py`, never `llm.generate_str`)
  relays bytes between the two admin ports using its existing hand-rolled
  clients (`git_admin_client.py`, and the new `workspace_admin_client.py`) -
  `sync_to_gateway()` before staging or executing a push and after every
  turn, `sync_to_workspace()` before and after every turn. The LLM never
  sees a bundle byte and has no tool that triggers this - it's pure harness
  plumbing, the same "structurally unreachable, not just unlisted" property
  `push_execute` already has.

**Why the Orchestrator relays, rather than a new network directly between
`git-mcp` and `workspace-mcp`.** The first version of this design gave the
two a shared internal network so `git-mcp` could pull bundle bytes itself.
That would have been the *first* crack in an invariant every network split
since ADR-0001 has upheld: `internal-workspace`/`internal-chat`/
`internal-memory`/`internal-docker-proxy`/`internal-git` are all separate
specifically so no two MCP servers can reach each other directly - only the
Orchestrator ever sits on more than one. Routing the relay through the
Orchestrator's harness instead - exactly the pattern `chat_client.py` and
`git_admin_client.py` already use for other cross-boundary plumbing - keeps
that invariant intact and needs no new network at all; both admin ports are
reached over networks that already exist (`internal-workspace`,
`internal-git`).

**Push semantics change slightly.** `push_execute` now pushes the gateway's
`refs/heads/<branch>` to `origin/<branch>` (by name), not `HEAD:<branch>` -
a bare mirror has no single checked-out `HEAD` to speak of. This means the
agent must create/commit to a local branch of that exact name in the
Workspace (and it must have been synced - the harness does this
automatically before staging and again before executing) before requesting
a push under that name. Slightly less magic than "push whatever I'm on
under a different name," and arguably clearer.

### 4. What this does not defend against (accepted, not solved here)

Deliberately out of scope for this ADR, in increasing order of how much
they'd cost to fix:

- **Egress is not host:port-restricted.** `git-egress` is a normal outbound
  network scoped to `git-mcp` alone (unchanged from ADR-0003 §5), but
  nothing stops arbitrary code running in `git-mcp` from making an outbound
  connection to a host other than the configured remote - only the
  container's own code chooses that host today. Closing this needs new
  infrastructure (an egress-filtering proxy or firewall rule keyed on the
  resolved remote host), not a compose-only change, and is tracked as a
  follow-up in the same category as the docker-socket-proxy's
  category-only gap (README's Further Threats item 7).
- **`git-mcp` still runs as root, with its full default capability set, and
  without a read-only root filesystem.** `no-new-privileges` is applied in
  `docker-compose.yml` (a real, if narrow, second layer - the process can't
  re-acquire privilege via a setuid/setcap binary even under RCE), but
  `cap_drop: [ALL]` was tried and reverted (confirmed live): it also strips
  `CAP_DAC_OVERRIDE`, which root needs to read the bind-mounted deploy key
  whenever its host-side file isn't owned by UID 0 - the normal case - so
  `_prepare_ssh_key` failed with `EACCES` on every single start, before
  ssh-agent ever came up. A correct version of this (`cap_drop: [ALL]` plus
  `cap_add` for just `DAC_OVERRIDE`/`CHOWN`/`FOWNER`, or a fixed non-root
  UID the deploy key is `chown`-able to instead) is a further hardening
  step, not done here - along with `read_only: true` (ssh-agent's socket,
  the deploy key's private copy, and bundle temp files all need somewhere
  writable, which a plain non-root user doesn't resolve by itself).
- **A `git-mcp` RCE can still push, and can still use the key.** Nothing in
  this ADR (or ADR-0003) stops code execution *inside `git-mcp`'s own
  process* - a bug in its Python, not a git side effect - from calling
  `push_execute` itself or invoking `git push` directly, bypassing the
  branch-pattern check and the human-approval gate entirely, and from using
  the loaded ssh-agent identity to do it (though not from exfiltrating the
  raw key material, since it's never read back off disk once loaded). The
  only way to make the approval gate itself survive a `git-mcp` compromise
  is to move the signing capability out of `git-mcp` into a separate signer
  that only signs when the Orchestrator's harness says a human approved -
  so `git-mcp` can't push unilaterally even with full code execution.
  Considered and explicitly **not built** here: it's a genuinely separate
  piece of infrastructure (a second credential-holding service, a protocol
  between it and the Orchestrator, its own attack surface), disproportionate
  to what this ADR set out to fix. The residual risk is bounded on the
  *other* side of the wire instead - the deploy key is scoped to one repo,
  and branch protection/required reviews on that repo are what stand
  between a `git-mcp` compromise and a merged change, not anything in this
  topology.

## Testing & Validation

`scripts/validate-phase3.sh`:
- Step 3 is now a negative check: a file written into `git-mcp`'s gateway
  path must **not** be visible from `workspace`'s `/repo` (the inverse of
  ADR-0003's original "shared volume" assertion - this is the regression
  guard against ever reintroducing it).
- Step 7's chat script now asks the agent to `git commit` via
  `workspace_exec` directly, matching the tool surface this ADR leaves it
  with, rather than a `git_commit` tool that no longer exists.
- New step 10 (opt-in, same `GIT_REMOTE_URL` gate as steps 7-9): plants a
  malicious `pre-push` hook and points the gateway's on-disk
  `core.hooksPath` directly at it - simulating "the on-disk config got
  clobbered somehow", the exact scenario `HARDENED_GIT_ARGS` exists for -
  then runs a real push_request/approve/execute cycle and asserts the
  planted hook never fired. This is the test the "doubly enforce no side
  effects" ask above resolves to: not just believing the `-c` flags work,
  but a run that would fail loudly if they didn't.

## Consequences

**Positive**
- Removes the shared-volume-as-code-execution vector at its source, not by
  enumerating and blocking each git config key that can trigger it.
- Restores real git hook support for the agent's own workflow (lint/test
  frameworks that hook into commit, etc.) - ADR-0003 had to forbid this
  entirely; it's now safe because of *where* it runs, not despite it.
- `git-mcp`'s LLM-facing tool surface is now about as narrow as a git
  integration can be: two tools, neither taking a config/hook/remote
  parameter. Closer to cornerstone 9's ideal than ADR-0003's fourteen-tool
  surface was.
- No new network, and no weakening of the "no two MCP servers reach each
  other" invariant every prior ADR's segmentation depends on.

**Negative / accepted risk**
- A second hand-rolled harness relay (`bundle_sync.py`) alongside
  `chat_client.py`/`git_admin_client.py` - more harness-level plumbing to
  keep deliberately minimal, same caution ADR-0003 already named for the
  approve/deny parser.
- Sync is unconditional (every turn, both directions) rather than
  triggered only when something actually changed - simpler and
  correctness-first, at the cost of a `git bundle create`/`fetch` round
  trip most turns don't need. Not a security tradeoff, a performance one;
  revisit if turn latency becomes a problem.
- The three gaps in Decision 4 above are real, accepted, and load-bearing
  for anyone relying on this ADR's guarantees - in particular, "the human
  approval gate can't be bypassed" now implicitly assumes `git-mcp`'s own
  process integrity, which ADR-0003's version of this design also assumed
  but never stated as sharply, since ADR-0003 had additional unpatched
  vectors (the hooksPath one this ADR fixes) that would have been reached
  first.

**Follow-ups tracked for later phases**
- Host:port-scoped egress filtering for `git-mcp` (Decision 4).
- Non-root user + `read_only: true` for `git-mcp` (Decision 4).
- A separate signer to make push approval survive a `git-mcp` RCE
  (Decision 4) - the only follow-up here that's a materially new piece of
  infrastructure rather than a hardening pass on what exists.
- Making `bundle_sync`'s relay conditional (skip a direction with nothing
  new to send) instead of unconditional every turn, if latency warrants it.

## Alternatives Considered

- **A direct network between `git-mcp` and `workspace-mcp`, `git-mcp` pulls
  bundle bytes itself.** Rejected - see Decision 3's "why the Orchestrator
  relays" above; breaks the one invariant every prior network split in this
  project has upheld.
- **A shared data-only volume for bundle files instead of the exec-relay.**
  Simpler to build, and would have kept `network_mode: none` on the
  Workspace without the base64-over-MCP transport - but reintroduces a
  writable mount shared between the trusted and untrusted sides, which is
  the exact category of thing this ADR is trying to eliminate, even scoped
  to inert files. Rejected in favor of a transport with no shared
  filesystem at all.
- **A live git-wire-protocol tunnel (`upload-pack`/`receive-pack`) piped
  through `docker exec` instead of discrete bundles.** Would also avoid a
  shared volume, but is a bidirectional live stream through
  `workspace-mcp` - the same class of problem the reverted
  `docker-socket-proxy` nginx replacement ran into (README's "Docker socket
  proxy" section): relaying a raw protocol stream is real infrastructure,
  where a bundle is one inert blob and two `subprocess.run` calls. Rejected
  as disproportionate complexity for the same end result.
- **Keep `git-mcp` running local ops against a shared volume, but relocate
  only `.git`'s control surface (`GIT_DIR`) to a private volume while
  `GIT_WORK_TREE` stays shared.** An earlier, narrower fix considered before
  this ADR - it does close the specific `core.hooksPath`-via-shared-config
  vector, but `git-mcp` still executes every git operation, including
  `commit`, meaning any *other* future hook/filter vector still lands in
  the credential-holding container. Superseded by moving execution itself
  to the Workspace instead of just moving the config file it reads.
