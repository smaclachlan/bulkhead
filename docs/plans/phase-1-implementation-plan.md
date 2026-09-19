# Phase 1 Implementation Plan

Implements the architecture fixed in
[ADR-0001](../adr/0001-phase-1-four-container-architecture.md), scoped per
[implementation.md](../../implementation.md).

## Definition of done for phase 1

A human can open a local URL served by the Chat MCP, send a message, have it
reach an LLM inside the Orchestrator, have the LLM decide to run a shell
command, have that command execute *only* inside the network-isolated
Workspace container via the Workspace MCP's `docker exec` path, and see the
result relayed back to the chat UI. Every container in that path is built
from the Nix flake and started via `apps.up`.

Concretely, this is done when the end-to-end walkthrough in Milestone 6 below
passes, unmodified, on a clean checkout.

## Sequencing

Build bottom-up: the two "dumb" containers first (Workspace, Workspace MCP) so
the privileged exec path can be tested in isolation with `curl`/a CLI client
before the Orchestrator or an LLM is in the loop at all. Chat MCP next (also
independently testable). Orchestrator last, since it's the piece that depends
on both of the others existing and working.

---

### Milestone 0 — Flake skeleton

**Goal:** `nix flake check` passes with four empty-but-structured packages;
nothing runs yet.

- [ ] `flake.nix` with outputs `packages.{orchestrator,workspace,workspace-mcp,chat-mcp}-image`, each currently a minimal placeholder derivation.
- [ ] Per-component directory (`orchestrator/`, `workspace/`, `workspace-mcp/`, `chat-mcp/`) with its own `default.nix` or equivalent, wired into the flake.
- [ ] `apps.up` stubbed (prints "not implemented" — real implementation lands in Milestone 5).
- [ ] Decide, per component, `dockerTools.buildLayeredImage` vs. Dockerfile fallback (ADR-0001 §3) and note the choice in that component's directory.

**Definition of done:** `nix flake check` succeeds; `nix build .#workspace-image` (etc.) produces a loadable image for all four, even if the image does nothing yet.

---

### Milestone 1 — Workspace container

**Goal:** a minimal, network-isolated container that can be `docker exec`'d into by hand.

- [ ] Minimal base image + coreutils/shell (per `implementation.md`: enough for `echo`, `ls`, `cat` — not a full build toolchain yet).
- [ ] No network (`docker run --network none` or Compose equivalent — confirm in Milestone 5's Compose file too).
- [ ] No credentials, no MCP client, no inbound-listening process of any kind.

**Definition of done:** `docker run --network none --name pandora-workspace <image> sleep infinity` starts it; `docker exec pandora-workspace echo ok` works; `docker exec pandora-workspace sh -c "curl -s example.com"` fails (no network path).

---

### Milestone 2 — Workspace MCP

**Goal:** the sole privileged container, exposing exactly one tool.

- [ ] MCP server exposing `exec(command: string) -> {stdout, stderr, exit_code}`.
- [ ] Implementation is hardcoded to `docker exec <pre-configured-workspace-id> sh -c "<command>"` — container ID from config/env, not a caller-supplied parameter.
- [ ] No other docker subcommands reachable from the tool surface (no `run`, `rm`, `cp`, arbitrary socket access).
- [ ] Docker socket bind-mounted in; this is the only container in the topology with that mount (grep the Compose file in Milestone 5 to confirm).
- [ ] No internet egress configured for this container.

**Definition of done:** with Milestone 1's Workspace container running, an MCP client (a throwaway test script is fine here) can call `exec("echo hello")` and get back `{stdout: "hello\n", exit_code: 0}`; calling with a shell metacharacter payload still only ever reaches the one pre-configured container, never anything else on the host.

---

### Milestone 3 — Chat MCP

**Goal:** a local chat surface, independently testable without the Orchestrator.

- [ ] Bound to `127.0.0.1`, small HTTP/WebSocket endpoint per ADR-0001 §6.
- [ ] Token generated at container start; required on the endpoint.
- [ ] `chat_send(message: string)` tool for the Orchestrator side, plus a receive mechanism (poll or push) for messages the human sends in.
- [ ] Minimal web UI (a single HTML page is enough for phase 1) that hits the same endpoint.

**Definition of done:** starting the container prints a URL with the token in it; opening it in a browser shows a chat box; a message typed there is retrievable via the MCP-facing receive call (test with a stub script, since the Orchestrator isn't wired yet).

---

### Milestone 4 — Orchestrator

**Goal:** an `mcp-agent`-based harness with zero shell tools, wired to both MCP servers from Milestones 2 and 3.

- [ ] `mcp-agent` configured with exactly two MCP server connections: Workspace MCP, Chat MCP. No other tools registered.
- [ ] LLM provider configured per ADR-0001 §7 (one provider, API-key or OAuth via `mcp_agent.secrets.yaml`/env).
- [ ] `workspace_exec(command)` wired as a straight passthrough to Workspace MCP's `exec` — confirm by code inspection that no local shell/subprocess call exists anywhere in the Orchestrator's own code path.
- [ ] Chat loop: poll/receive from Chat MCP, send user message (+ any tool results) to the LLM, relay the LLM's reply back via `chat_send`.
- [ ] Internet egress limited to the LLM provider's API/auth endpoints; internal network reaches Workspace MCP + Chat MCP only.

**Definition of done:** with Milestones 1-3 running, starting the Orchestrator and sending it a chat message that requires no tool use gets a reply relayed back through Chat MCP.

---

### Milestone 5 — Compose wiring and `apps.up`

**Goal:** one command brings up all four containers with the correct network segmentation.

- [ ] `docker-compose.yml` (hand-written or generated from the flake — ADR-0001 §4) defining:
  - Workspace: `network: none`.
  - Workspace MCP: internal-only network shared with Orchestrator; `/var/run/docker.sock` bind mount; Docker socket access sufficient to `exec` into the Workspace container by name/ID.
  - Chat MCP: `127.0.0.1` port publish only; same internal network as Orchestrator.
  - Orchestrator: internal network (reaching Workspace MCP + Chat MCP) + internet egress; **no** other port publishes, no volume mounts that would grant filesystem access.
- [ ] `apps.up` (`nix run .#up`) builds all four images and runs `docker compose up`.
- [ ] `restart: on-failure` (or equivalent) on each service per ADR-0001 §4.

**Definition of done:** `nix run .#up` on a clean checkout brings up all four containers; `docker network inspect` confirms Workspace has no network attached and Workspace MCP/Chat MCP are not internet-reachable; only Orchestrator has an egress path out.

---

### Milestone 6 — End-to-end validation (phase 1 exit criteria)

**Goal:** prove the full path named in phase 1's success criteria, as a repeatable check.

- [ ] `nix run .#up` from a clean checkout.
- [ ] Open the printed Chat MCP URL (with token) in a browser.
- [ ] Send a message that requires a shell command (e.g. "list the files in the workspace").
- [ ] Confirm: Orchestrator calls `workspace_exec` -> Workspace MCP -> `docker exec` into Workspace -> real output comes back -> LLM's reply (incorporating that output) appears in the chat UI.
- [ ] Confirm containment held throughout: nothing outside the Workspace container executed the command; Workspace never had network access at any point; Workspace MCP's Docker socket was the only path used.
- [ ] Write this walkthrough up as a short runbook/checklist (`docs/plans/phase-1-validation.md` or similar) so it's repeatable, not just something done once by hand.

**Definition of done:** the walkthrough above passes without manual workarounds. This closes phase 1.

---

## Explicitly deferred past phase 1

Per `implementation.md` and ADR-0001's follow-ups: additional MCP servers
(search, Git egress, artifact egress), MCP gateway/allowlist layer,
docker-socket-proxy in front of Workspace MCP, multi-agent/multi-workspace
scenarios, MicroVM-backed runtime. None of these block the Milestone 6 exit
criteria and should not be pulled forward into phase 1 scope.
