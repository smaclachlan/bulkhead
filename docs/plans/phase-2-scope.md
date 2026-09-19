# Phase 2 Scope

Phase 1 ([implementation.md](../../implementation.md),
[ADR-0001](../adr/0001-phase-1-four-container-architecture.md)) proved the
core containment shape: Orchestrator -> Workspace MCP -> `docker exec` ->
Workspace, plus a local chat surface, with no shell on the Orchestrator and
Workspace fully network-isolated. `validation-results/phase-1/latest.json`
(14/17 checks passing) is the record of that.

Phase 2 does two kinds of work: **close gaps phase 1's own validation
surfaced**, and **add the capabilities below**. Nothing here reopens phase
1's container boundaries by accident - each item states which boundary it
touches.

## Carried over from phase 1 validation - fixed, needs a live re-run

The validation harness found three failures that the runbook explicitly
flagged as "real information about a phase-1 gap, not something to explain
away." Addressed as a precondition for phase 2 rather than folded into it -
new surface area (Memory MCP, a gateway layer, Kata) shouldn't land on top
of an unconfirmed isolation boundary. Root-caused and fixed in this pass;
**not yet re-verified live** (this environment has neither Nix nor Docker -
see `scripts/validate-phase1.sh` prerequisites). Re-run
`nix run .#up` then `sh scripts/validate-phase1.sh` before treating these as
closed.

1. **`step7.cross-container-isolation` (FAIL, fixed)** - `chat-mcp` could
   open a TCP connection to `workspace-mcp:8801` over the shared `internal`
   Compose network. `internal: true` blocks egress to the outside world but
   doesn't isolate members of the same network from each other. Per
   ADR-0001 §1, Workspace MCP should be reachable from the Orchestrator
   only. **Fix applied**: `docker-compose.yml` now splits the one shared
   `internal` network into `internal-workspace` (workspace-mcp +
   orchestrator only) and `internal-chat` (chat-mcp + orchestrator only) -
   chat-mcp and workspace-mcp no longer share a network at all, so the
   validation script's TCP probe should now fail at hostname resolution,
   not just connection refusal.
2. **`step7.tool-listing` (FAIL, fixed) and `step7.no-docker-in-workspace`
   (FAIL, fixed) - same root cause.** Both checks run through the same
   embedded Python MCP client in `validate-phase1.sh` (`run_mcp_check`,
   used for both the `exec` and `escape` modes) - so the empty `output: ""`
   recorded against `no-docker-in-workspace` and the `ExceptionGroup` from
   `tool-listing` are two symptoms of one broken script, not two separate
   bugs. Confirmed by diff against `orchestrator/src/orchestrator/
   chat_client.py`, which does the equivalent connection for real (verified
   live in Milestone 4): the validation script's inline client had
   `from mcp.client.streamable_http import streamable_http_client` (extra
   underscore - wrong name) and unpacked its `async with` into a 2-tuple
   `(read, write)`, where the working client unpacks a 3-tuple `(read,
   write, get_session_id)`. **Fix applied**: corrected the import name and
   unpacking to match `chat_client.py` exactly, and replaced the bare
   `except Exception as e: out["error"] = f"{type(e).__name__}: {e}"` with
   a recursive unwrap of `ExceptionGroup.exceptions` - anyio's TaskGroups
   collapse real errors into an opaque "unhandled errors in a TaskGroup (N
   sub-exception)" string unless you walk the group yourself, which is why
   the original failure was undiagnosable from its own recorded detail.
   Future validation-script bugs should now surface their real exception
   text instead of that generic message.
   `workspace/default.nix` was independently re-checked: `contents = [
   coreutils bashInteractive ]`, no docker package - so once the client
   bug is fixed, the underlying `docker ps` (expected to fail inside
   `pandora-workspace`) should behave as the check always intended.

## 1. MicroVM isolation via Kata Containers

README's "Micro VM Container sessions" cornerstone and ADR-0001's deferred
"MicroVM-backed runtime" follow-up. Kata swaps the OCI runtime from `runc`
(shared host kernel, namespace isolation) to a per-container lightweight VM
(QEMU/cloud-hypervisor guest, own kernel) - it's a drop-in runtime, not a
rewrite of the container boundary, so it composes with the existing
four-container Compose topology rather than replacing it.

- **Mechanism**: `containerd` + `containerd-shim-kata-v2`, with Docker
  configured to register `kata` as a runtime (`/etc/docker/daemon.json`
  `runtimes` block) and each Compose service opting in via
  `runtime: kata`. Requires hardware virtualization (KVM) on the host - if
  Pandora itself ever runs inside a VM (cloud dev box, CI), nested
  virtualization needs to be enabled, which is a real deployment
  constraint worth surfacing early.
- **Rollout order - recommend Workspace first, not all four at once**:
  Workspace is where the actual containment stakes are (arbitrary
  agent-issued shell commands execute there) - a kernel-level VM boundary
  matters most for the one container running untrusted-shaped input.
  Workspace MCP holds the Docker socket regardless of which runtime it's
  under, so Kata doesn't reduce *that* specific risk (tracked separately
  below as docker-socket-proxy) but does shrink the blast radius of a bug
  in Workspace MCP's own code reaching the host kernel. Chat MCP and the
  Orchestrator are lower-value Kata targets for now (no arbitrary command
  execution) - candidates for a later pass once the Workspace migration is
  proven, not a phase 2 requirement.
- **Compatibility note**: this repo already ruled out Podman for MicroVMs
  ("Podman Machine ... much more manual" - README, Sept 2026 note) -
  staying on Docker + Kata is consistent with that, not a new fork in the
  toolchain.
- **Open question**: whether `workspace-image`'s pure-Nix
  `dockerTools.buildLayeredImage` output is directly loadable under a Kata
  runtime the same way it is under `runc` today, or needs an adjusted base
  (Kata guests boot a minimal guest kernel + your rootfs - should be
  transparent, but worth confirming on the first real build).

## 2. Chat UI: connection & activity feedback

Right now the UI ([index.html](../../chat-mcp/src/chat_mcp/static/index.html))
polls `/api/messages` every second and shows nothing between "message sent"
and "reply appears" - no signal the Orchestrator is even alive, let alone
working on it. Two distinct pieces of feedback, using the narrow-vocabulary
pattern from README cornerstone 9 (which already names almost exactly this
tool: `send_status(state: enum[...])`):

- **Presence ("is the agent connected")**: `chat_receive`'s poll loop
  (`orchestrator/src/orchestrator/main.py`) already calls into Chat MCP
  every `poll_timeout` seconds (default 30s) whether or not a message is
  waiting. Have `ChatState` record a `last_seen` timestamp on *every*
  `chat_receive` invocation (not just when it returns a message), and add
  a `GET /api/status` endpoint the UI polls alongside `/api/messages`. UI
  shows connected/stale based on `last_seen` being within ~2x
  `poll_timeout`. No new MCP tool needed - this rides the existing
  long-poll.
- **Activity ("is it working on my message")**: add one new harness-level
  tool, `chat_set_status(state: enum["received", "working", "done",
  "error"])`, called by the Orchestrator's loop itself (not the LLM - same
  reasoning ADR-0001 gives for keeping `chat_send`/`chat_receive` off the
  LLM's tool list) at each stage: `received` right after
  `chat.receive()` returns a message, `working` for the duration of
  `llm.generate_str()`, `done`/`error` right before/after `chat.send()`.
  Closed enum, no freeform field - stays inside cornerstone 9 even though
  it's a new tool. UI shows a typing-indicator-style state next to the
  status dot.

## 3. CLI access to chat

Chat MCP already has two faces: the MCP tool surface (`chat_send`/
`chat_receive`, for the Orchestrator) and a REST surface (`/api/messages`,
`/api/send`, for the browser UI) behind the same bearer token. A CLI client
is a third consumer of the *existing* REST surface - no new container, no
new network path, no change to any containment boundary.

- Proposed: `chat-mcp/src/chat_mcp/cli.py`, a small Python script (stdlib
  `urllib` + a loop, consistent with what's already in the container's own
  test scripts) that polls `/api/messages?since=N` and posts to
  `/api/send`, mirroring `index.html`'s JS logic in a terminal. Two modes:
  - REPL: persistent terminal chat, analogous to the browser tab.
  - One-shot: `pandora-chat send "message" --wait` for scripting/piping.
- Exposed as a flake app (`nix run .#chat -- <token>` or reading
  `CHAT_MCP_TOKEN`/a printed URL from `.env`), matching the existing
  `apps.up` / `apps.build-*` pattern rather than a hand-run script.
- Runs against `127.0.0.1:8787` from the host - the same access the
  browser already has, so this doesn't add exposure.

## 4. Memory MCP server

Adding the reference implementation at
[modelcontextprotocol/servers/src/memory](https://github.com/modelcontextprotocol/servers/tree/main/src/memory) -
a knowledge-graph memory server (entities/relations/observations) backed by
a JSON file, Node/TypeScript, configured via `MEMORY_FILE_PATH`.

This is a bigger decision than it looks, for two reasons worth calling out
explicitly rather than glossing over:

- **It's a fifth container** and Pandora's first Node-based one (the other
  three Python services are Dockerfile + `requirements.txt`; this would be
  Dockerfile + `package.json`, same per-image pattern as ADR-0001 §3, just
  a different runtime). Network shape matches Chat MCP's, not Workspace
  MCP's: internal-only, reachable from the Orchestrator only, no internet
  egress, no Docker socket. Needs a named volume for its JSON store so
  memory survives container restarts (state.py's in-memory chat log
  deliberately doesn't persist - this is the opposite: it's supposed to).
- **It breaks the "one tool" invariant.** ADR-0001 §2 calls out, as a
  deliberate narrowing, that the LLM's *only* callable tool is
  `workspace_exec` - Chat MCP is reached by hand-rolled harness code
  specifically so the LLM's tool list stays at one entry. The memory
  server exposes nine tools (`create_entities`, `create_relations`,
  `add_observations`, `delete_entities`, `delete_observations`,
  `delete_relations`, `read_graph`, `search_nodes`, `open_nodes`), all
  freeform-text-bearing by design - a knowledge graph can't be a closed
  enum. Attaching it (`server_names=["workspace", "memory"]`) is a
  legitimate, deliberate scope decision, but it's the first time this
  project accepts a freeform-text tool surface beyond the human chat
  channel, and it's worth being explicit about rather than adding quietly.
  Two follow-on effects:
  1. This is exactly the threshold ADR-0001 named for revisiting the
     deferred MCP gateway/allowlist layer ("once more than one downstream
     MCP server exists") - see item 6 below. Worth doing that alongside,
     not after.
  2. New entry for README's "Further Threats" list: memory-store
     poisoning. Content the agent reads via `workspace_exec` (a file, a
     command's output) could contain injected text instructing it to
     write something into memory that resurfaces - and gets trusted - in
     a *later* session. Not solved by this phase; flagging it as a known
     risk to design around (e.g., surfacing what's about to be persisted
     to the human before it's written, later) rather than something the
     memory server itself protects against.

## 5. Network segmentation fix

Done as part of "Carried over" above (`internal-workspace` /
`internal-chat` split) - listed again here only to flag that it was a
precondition for item 4: adding a second internal-only MCP server (Memory)
onto the old shared `internal` network would have just added a second
instance of the same gap. Memory MCP's own network placement (below) should
follow the same pattern - its own internal network joined only by itself
and the Orchestrator, not reused from Chat MCP's or Workspace MCP's.

## 6. MCP gateway / allowlist layer (e.g. ToolHive)

ADR-0001 deferred this explicitly with the condition "once more than one
downstream MCP server exists" - phase 2 crosses that line (Workspace MCP +
Chat MCP already, Memory MCP added here). Worth evaluating now rather than
after a second and third server accumulate without one. Scope for phase 2:
investigate + prototype, not necessarily a hard requirement to ship before
Memory MCP lands, but the two should be sequenced deliberately rather than
Memory MCP shipping first and the gateway arriving as an afterthought.

## 7. Docker-socket-proxy in front of Workspace MCP

Explicitly deferred, not rejected, in ADR-0001 §5 ("tracked as a phase 2
follow-up"). Still relevant independent of Kata (item 1) - Kata shrinks the
blast radius of a *code* bug in Workspace MCP reaching the host kernel; a
socket proxy shrinks the blast radius of what Workspace MCP's own Docker
socket access can do even if its code is fully compromised. The two are
complementary, not redundant - recommend both land in phase 2 rather than
treating Kata as a substitute for this.

## Explicitly out of scope for phase 2

Carried forward from ADR-0001's own "not phase 1 scope" list, still not
ready:

- **Git MCP / artifact egress** (README's Egress section) - the two
  approved egress paths still don't exist; nothing in phase 2 needs them,
  and adding them alongside a runtime migration (Kata) and a topology
  change (item 5) would be too much moving at once. Next candidate for
  phase 3.
- **Multi-agent / multi-workspace scenarios** - no phase 2 item requires
  this; Kata's per-container VM boundary is a prerequisite worth having
  *before* multiple workspaces exist, but standing up multiples is not
  itself phase 2 work.
- **Full build toolchain in Workspace** (README point 7) - still just
  coreutils/shell; nothing above requires more, and expanding it is
  orthogonal to isolation/UX/memory work.
- **Resource exhaustion / rate limiting** (README's Further Threats item
  4) - real and still unaddressed, but no phase 2 item above depends on
  it and it's a clean standalone unit of work; flagging so it doesn't get
  forgotten, not proposing to bundle it in.

## Not yet decided

Mirroring `implementation.md`'s own pattern of leaving reversible choices
open until they block something concrete:

- Kata rollout breadth: Workspace-only for the whole of phase 2, or also
  Workspace MCP once the socket-proxy (item 7) is in place and its own
  blast radius is smaller?
- Whether the MCP gateway (item 6) sits in front of just the two new
  additions (Memory, and Workspace MCP's split-off network) or is
  retrofitted in front of Chat MCP too.
- CLI client: ship inside `chat-mcp/` (simplest - it's a client of that
  service's own API) or as a genuinely separate top-level component if it
  grows scope later (e.g. talking to multiple Pandora instances).
- Memory MCP's volume/backup story - a knowledge graph that's useful is
  also the first piece of Pandora state worth *not* losing on a container
  recreate; not decided whether that's a bind mount, a named volume, or
  something the Chat/Git-egress-style human-approval pattern should touch
  later (e.g. reviewing what's in memory).
