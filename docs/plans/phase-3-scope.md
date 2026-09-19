# Phase 3 Scope

Phase 1 ([ADR-0001](../adr/0001-phase-1-four-container-architecture.md))
proved the core containment shape. Phase 2
([ADR-0002](../adr/0002-phase-2-isolation-ux-memory.md)) tightened isolation
(Kata, docker-socket-proxy), improved chat UX, and added persistent memory -
14/15 automated checks pass
(`validation-results/phase-2/latest.json`); the one open gap is
`step7.cross-session-recall` (a fresh Orchestrator process doesn't yet
reliably recall a memory fact in a new conversation without it being
restated) - worth root-causing before phase 2 is called fully closed, but it
doesn't block phase 3 starting, since Git MCP doesn't depend on Memory MCP.

Both ADR-0001 and ADR-0002 deferred Git MCP / artifact egress (README's
"Egress" section) explicitly to a later phase. Phase 3 is that phase, scoped
down to just Git MCP - artifact egress (`docker cp` egress) stays deferred
further, since it's a separate mechanism with its own open questions
(scanning/size-capping, per README's Egress section item 2) and nothing
requires shipping both together.

## Why now

Stuart's framing: Bulkhead needs a real Git MCP before it's ready for actual
trialling - without it, any code the agent produces is stuck inside the
Workspace container with no way out except a human manually copying it,
which defeats the point of using Bulkhead for real work.

## 1. Resolving README point 8 - where the Workspace's working tree lives

Not actually a Git-MCP-specific question, but Git MCP forces an answer:
today the Workspace container has **no working-tree volume at all** - it's
whatever the image bakes in (coreutils + a shell, per `implementation.md`'s
v1 scope), with nothing mounted. README point 8 named two options and left
the choice open:

- Mapped in host container workspace.
- Separate workspace in the container, syncing to an external server via the
  Git MCP.

**Phase 3 picks the second option**: a Docker-managed named volume (not a
host bind mount) shared between `workspace` and the new `git-mcp` container.
A host bind mount would leak the *host's* filesystem into a topology that's
otherwise entirely container-scoped state (matching how `memory-data` and
Chat MCP's approach already keep all persistent state inside Docker-managed
volumes, not host paths) - see [ADR-0003](../adr/0003-phase-3-git-mcp.md)
Decision 1 for the full reasoning.

## 2. Git MCP container - local git operations

Per README's Egress section: "Local git work (commit, branch, diff, log)
isn't gated - the Workspace Sandbox is already fully network isolated ...
and the Workspace doesn't even need git installed since the MCP can do this
local work on the Agent's behalf too."

- New container, `git-mcp`, with `git` installed (Workspace still doesn't
  need it - confirmed by this design, not just asserted).
- Mounts the same shared working-tree volume as `workspace` (see item 1).
- Tools given directly to the LLM (`server_names=[..., "git"]`, same pattern
  as `workspace`/`memory`): read-only (`status`, `diff`, `log`,
  `branch_list`) and local-write (`commit`, `create_branch`, `checkout`) -
  all ungated, matching README's explicit carve-out.
- No Docker socket, no docker CLI - a different privilege shape from
  Workspace MCP entirely (filesystem + eventual network egress to the git
  remote, not host container control).

## 3. The one gated action - push

README's Egress section: "The MCP itself only has limited powers for the one
action that actually crosses the boundary: push to a pre-configured remote
and branch pattern, no arbitrary remotes, no force-push, no git config
changes, no hooks. Holds the auth credentials itself so the Workspace
Sandbox/Agent never see them, and requires human approval before an external
push goes out."

This is the item that needs its own ADR decision (see
[ADR-0003](../adr/0003-phase-3-git-mcp.md) Decision 3) - it's a new
instance of the "human-approval gate" pattern README cornerstone 9 already
names, and the project doesn't have a generic mechanism for that yet (Chat
MCP's `chat_send`/`chat_receive` split is the closest precedent: something
harness-only, never LLM-callable). Phase 3 defines a `push_request` /
`push_execute` split that reuses that precedent rather than inventing a new
approval channel.

## 4. Credentials - SSH deploy key

Deploy key (not a broad PAT) mounted read-only into `git-mcp` only, scoped to
the single pre-configured remote. Matches README's "holds the auth
credentials itself so the Workspace Sandbox/Agent never see them" - the key
never touches the shared volume or any other container.

## 5. Network segmentation for git-mcp

Same pattern phase 2 established for Memory MCP: its own internal network to
the Orchestrator (`internal-git`, reachable only by `git-mcp` and
`orchestrator`), **plus** a new egress-only network (`git-egress`) for
reaching the actual git remote (e.g. GitHub/GitLab over SSH) - scoped to
`git-mcp` alone, not shared with the Orchestrator's own `egress` network
(which is for the LLM provider only). Least privilege in both directions:
Orchestrator can't reach the git remote directly, `git-mcp` can't reach the
LLM provider.

## Explicitly out of scope for phase 3

- **Artifact egress** (`docker cp`-based, README's Egress item 2) - separate
  mechanism, separate open questions (scanning/size caps), no dependency on
  Git MCP landing first or vice versa.
- **Fixing `step7.cross-session-recall`** (phase 2's one open validation
  gap) - unrelated to Git MCP; tracked separately, doesn't block this phase.
- **Multi-agent / multi-workspace scenarios** - still not required by
  anything here; one shared working-tree volume assumes one Workspace.
- **Kata for `git-mcp` itself** - candidate for a later pass once the
  Workspace Kata migration (phase 2) has run in real use; `git-mcp` runs no
  agent-issued shell input (all its git operations are parameterized calls,
  not arbitrary commands), so it's a lower-value Kata target than Workspace
  was, same reasoning ADR-0002 gave for excluding Chat MCP/Orchestrator.

## Not yet decided

- Shallow vs. full clone for the initial sync into the shared volume.
- Whether `git-mcp` re-clones on every container recreate or only when the
  volume is empty (affects how "fresh checkout" vs. "resume prior session"
  behave differently).
- Whether the branch-pattern allowlist (e.g. `agent/*`) is a single fixed
  pattern in `.env`, or needs to support multiple patterns/remotes for
  multi-repo use later - phase 3 ships a single pattern, single remote.
