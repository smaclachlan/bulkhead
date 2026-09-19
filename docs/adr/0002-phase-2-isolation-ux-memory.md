# ADR-0002: Phase 2 — Kata Isolation, Chat UX Feedback, and Persistent Memory

- Status: Proposed
- Date: 2026-09-19
- Supersedes: none
- Amends: [ADR-0001](0001-phase-1-four-container-architecture.md) (§5's
  deferred docker-socket-proxy remains deferred; §2's "one tool" invariant is
  deliberately narrowed, not dropped, by Decision 4 below)
- Related: [phase-2-scope.md](../plans/phase-2-scope.md),
  [README.md](../../README.md),
  `validation-results/phase-1/latest.json` (19/19, phase 1 closed)

## Context

Phase 1 (ADR-0001) proved the core containment shape — Orchestrator has no
shell, Workspace is reachable only through Workspace MCP's single `exec`
tool, Workspace itself has no network — and closed its validation gaps
(network split, MCP-client version fixes) before any new surface area was
allowed to land on top of it. [phase-2-scope.md](../plans/phase-2-scope.md)
drafted seven candidate items for phase 2. This ADR formalizes the three that
carry real architectural weight — the ones that change a containment
boundary, a tool-surface invariant, or introduce state that must survive
restarts — as decisions, rather than leaving them as scope-doc prose. Items
that don't change any boundary (the CLI client, the already-shipped network
split) are noted but don't need a decision record of their own.

Stuart's own framing for this ADR: phase 2 needs to demonstrably (a) improve
the chat user experience, (b) tighten isolation using Kata Containers, and
(c) give the memory server real cross-session recall — and testing has to
verify all three, not just that the code merged.

## Decision

### 1. MicroVM isolation via Kata Containers — Workspace container first

Swap the OCI runtime for the Workspace container from `runc` to Kata
(`containerd-shim-kata-v2`, hardware-virtualized QEMU/cloud-hypervisor guest
kernel), via Docker's `runtimes` config and `runtime: kata` on that one
Compose service. This is additive to ADR-0001's topology, not a replacement
of it: the four/five-container boundary stays exactly as decided, Kata just
changes what enforces the wall around one of them.

**Workspace only for phase 2**, not all containers, because Workspace is the
one container whose entire job is running arbitrary agent-issued shell
commands — it's where a kernel-level VM boundary buys the most containment
per unit of operational complexity. Workspace MCP keeps `runc` for now: it
holds the Docker socket regardless of runtime, so Kata doesn't reduce that
specific risk (item 3's docker-socket-proxy is the mitigation for that), and
putting Workspace MCP under Kata is a candidate for a later pass once the
Workspace migration itself is proven in production use, not bundled into the
same change. Chat MCP and the Orchestrator run no untrusted input through a
shell at all and are not Kata candidates in phase 2.

This requires KVM on the host; if Bulkhead ever runs nested (a cloud dev box,
CI), nested virtualization must be enabled — a deployment constraint to
surface in the repo's setup docs, not just this ADR.

### 2. Chat UX feedback: presence + activity status

Two additive signals, both server-state-only (no LLM-visible tool added):

- **Presence**: `ChatState` records `last_seen` on every `chat_receive` poll
  (not just when a message is returned); a new `GET /api/status` endpoint
  exposes it; the UI derives connected/stale from `last_seen` against
  ~2x `poll_timeout`.
- **Activity**: one new harness-level tool, `chat_set_status(state:
  enum["received", "working", "done", "error"])`, called by the
  Orchestrator's own loop code at each stage boundary — never by the LLM,
  for the same reason ADR-0001 kept `chat_send`/`chat_receive` off the LLM's
  tool list. Closed enum, no freeform field, so this stays inside README
  cornerstone 9's narrow-vocabulary rule even though it's new tool surface.

### 3. Docker-socket-proxy in front of Workspace MCP

Ship the proxy ADR-0001 §5 explicitly deferred (not rejected). Independent of
and complementary to Decision 1: Kata shrinks the blast radius of a *code*
bug in Workspace MCP reaching the host kernel; the proxy shrinks what
Workspace MCP's Docker socket access can do even if its code is fully
compromised. Both land in phase 2 rather than treating one as a substitute
for the other.

### 4. Memory MCP server — a fifth container, and a deliberate narrowing of ADR-0001 §2

Add the reference `memory` MCP server
([modelcontextprotocol/servers/src/memory](https://github.com/modelcontextprotocol/servers/tree/main/src/memory)),
a knowledge-graph store (entities/relations/observations) backed by a JSON
file on a named volume, attached to the LLM as a second server
(`server_names=["workspace", "memory"]`).

This is called out as its own decision, not folded into "add a container,"
for two reasons:

- **Topology**: it's Bulkhead's first Node/TypeScript container (Dockerfile +
  `package.json`, same per-image pattern as ADR-0001 §3's Python
  containers, different runtime). Network shape matches Chat MCP's:
  internal-only, reachable from the Orchestrator alone, no internet egress,
  no Docker socket, on its **own** internal network — not reused from Chat
  MCP's or Workspace MCP's, per the same reasoning that split the network in
  phase 1 (two servers sharing one internal network is the same gap twice).
  It gets a named volume for its JSON store specifically because it's
  supposed to survive container recreation — the opposite of `ChatState`'s
  deliberately in-memory chat log.
- **Tool-surface invariant**: ADR-0001 §2 made "the LLM's only callable tool
  is `workspace_exec`" a deliberate narrowing of what `mcp-agent` would
  otherwise allow. The memory server exposes nine freeform-text-bearing
  tools (`create_entities`, `create_relations`, `add_observations`,
  `delete_entities`, `delete_observations`, `delete_relations`,
  `read_graph`, `search_nodes`, `open_nodes`) — a knowledge graph can't be a
  closed enum. This ADR accepts that narrowing as a deliberate, scoped
  exception for this one server, not a reversal of the invariant itself:
  `workspace_exec` stays the only tool that can touch the shell/Workspace
  boundary; memory tools can only read/write the knowledge graph.
  Consequences of crossing this line:
  1. It trips the exact condition ADR-0001 named for revisiting the
     deferred MCP gateway/allowlist layer ("once more than one downstream
     MCP server exists") — see Decision 5.
  2. New entry for README's Further Threats list: **memory-store
     poisoning**. Content the agent reads via `workspace_exec` could carry
     injected text instructing it to persist something that gets trusted in
     a *later* session. Not solved by this phase; tracked as a known risk
     (candidate mitigation: surface what's about to be persisted to the
     human before it's written, in a later phase — not required for phase 2
     to ship).

### 5. MCP gateway / allowlist layer — investigate and prototype, not a hard gate

ADR-0001 deferred this with the trigger condition "once more than one
downstream MCP server exists"; Decision 4 crosses that line. Phase 2 scope is
investigation + a prototype (e.g. ToolHive), sequenced deliberately alongside
Memory MCP rather than shipped first with the gateway arriving as an
afterthought — but not a hard requirement gating Memory MCP's release, per
[phase-2-scope.md](../plans/phase-2-scope.md)'s own framing.

## Testing & Validation

Phase 1 established the pattern of a written runbook plus an automated
harness that writes a timestamped, structured result record
(`docs/plans/phase-1-validation.md` /
`scripts/validate-phase1.sh` / `validation-results/phase-1/*.json`). Phase 2
follows the same pattern (`docs/plans/phase-2-validation.md`,
`scripts/validate-phase2.sh`, `validation-results/phase-2/`) — the script
header already anticipates this ("copy this file to validate-phase2.sh,
change PHASE below"). Per Stuart's requirement, the phase 2 runbook must
independently verify all three headline changes, not just confirm they
merged:

- **Improved chat UX** (Decision 2):
  - Kill the Orchestrator process (or block its poll) and confirm
    `/api/status` flips the UI to "stale" within ~2x `poll_timeout`, then
    recovers on restart — presence has to be *observed to change*, not just
    present at steady state.
  - Send a chat message and assert the UI shows `received` → `working` →
    `done` (or `error` on an induced failure, e.g. a bad LLM credential) in
    order, not just that the final state eventually appears.
  - CLI client (`bulkhead-chat send "..." --wait`) round-trips a message
    against the same REST surface the browser uses, confirmed against a live
    stack.
- **Isolation via Kata** (Decision 1):
  - `docker inspect` the running Workspace container and assert its runtime
    is `kata`, not `runc` (a config-only regression — Compose says `kata`
    but Docker silently falls back — is the likely failure mode worth
    checking for explicitly).
  - Re-run phase 1's own isolation checks (`step7.cross-container-isolation`,
    `step7.no-docker-in-workspace`) against the Kata-backed Workspace to
    confirm the runtime swap didn't regress the boundaries ADR-0001 already
    proved under `runc`.
  - A positive isolation probe: confirm the Workspace guest's kernel version
    (`uname -r` via `workspace_exec`) differs from the host's — direct
    evidence it's actually a separate kernel, not just a relabeled `runc`
    container.
- **Memory persistence across sessions** (Decision 4):
  - Have the agent write an observation via a memory tool, `docker compose
    restart memory-mcp` (or recreate the container), and confirm a fresh
    query (`search_nodes`/`open_nodes`) still returns it — proves the named
    volume, not just in-process state, is what's holding the data.
  - Close out one Orchestrator session/conversation entirely and start a new
    one; confirm the new session's LLM can recall a fact stored in a prior
    session without it being restated in-context — this is the actual
    "remembers between sessions" property, distinct from surviving a
    container restart within the same session.
  - Confirm the network-isolation check extends to Memory MCP: it should be
    reachable from the Orchestrator and from nothing else (same style of
    check phase 1 already runs for Chat MCP/Workspace MCP's split networks).

Definition of done for phase 2 mirrors phase 1's: the runbook's checks pass
on a clean checkout, recorded as a timestamped JSON result under
`validation-results/phase-2/`, before phase 2 is considered closed.

## Consequences

**Positive**
- Kata's blast-radius reduction lands on exactly the container where it
  matters most, without re-touching the four-container topology ADR-0001
  already validated.
- Chat feedback and the CLI are both additive to Chat MCP's existing REST
  surface — zero new containment surface, so they carry none of this ADR's
  real risk and are testable independently of everything else here.
- Making the memory-server tool-surface exception explicit (Decision 4)
  means it's a reviewed scope decision, not an invariant that quietly eroded.

**Negative / accepted risk**
- Kata adds a real host dependency (KVM, nested-virt support in CI/cloud dev
  boxes) that `runc`-only phase 1 didn't have — accepted because Workspace is
  exactly the container where that cost buys containment.
- The LLM's tool list is no longer provably one entry; a bug or prompt
  injection that manipulates memory tools can now write persistent state
  that outlives a single conversation. Accepted as a scoped, monitored
  exception (see Decision 4's poisoning risk) rather than solved outright —
  the mitigation (pre-persistence human review) is explicitly deferred, not
  shipped, in phase 2.
- A fifth container, a second internal network, and a new runtime path
  (Kata) landing in the same phase is more simultaneous change than ADR-0001
  took on at once; accepted because each item validates independently (see
  Testing & Validation) rather than only as an end-to-end whole.

**Follow-ups tracked for later phases**
- Kata for Workspace MCP itself, once the socket-proxy (Decision 3) is
  proven and Workspace's own Kata migration has run in real use.
- Pre-persistence human review for memory writes (mitigates the poisoning
  risk named in Decision 4, doesn't eliminate it here).
- Retrofitting the MCP gateway (Decision 5) in front of Chat MCP too, if the
  Memory MCP prototype validates the approach.
- Git MCP / artifact egress, multi-agent/multi-workspace scenarios, full
  build toolchain in Workspace, resource exhaustion/rate limiting — all
  carried forward from ADR-0001's and phase-2-scope.md's out-of-scope lists,
  still not phase 2 work.

## Alternatives Considered

- **Kata across all five containers at once.** Rejected: Chat MCP and the
  Orchestrator run no agent-issued shell input, so the marginal containment
  value is low relative to the operational cost (KVM dependency everywhere)
  and the debugging cost of migrating everything simultaneously.
- **Ship the docker-socket-proxy instead of Kata, as the single phase-2
  isolation change.** Rejected as an either/or: the two mitigate different
  attackers (a code bug vs. a fully compromised process) and
  phase-2-scope.md is explicit that they're complementary, not substitutes.
- **Give the LLM the memory tools with no scope discussion, treating it as
  "just another MCP server."** Rejected — ADR-0001 named the one-tool
  invariant as a deliberate design choice, so relaxing it needs its own
  decision record (this one) rather than happening as an implicit side
  effect of adding a container.
- **Defer Memory MCP until after the MCP gateway (Decision 5) ships.**
  Considered; phase-2-scope.md explicitly recommends sequencing them
  deliberately rather than gating one on the other, since the gateway is
  investigate-and-prototype scope, not a hard dependency.
- **Test memory persistence only via container restart, skip the
  cross-session recall check.** Rejected — surviving a restart proves the
  volume works but not that a *new conversation* can recall old facts, which
  is the actual capability being added; both checks are kept in Testing &
  Validation above.
