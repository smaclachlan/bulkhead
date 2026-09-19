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

**Goal:** `nix flake check` passes. Per ADR-0001 §3, only Workspace is a pure
Nix package; the three Python containers are Dockerfile-based, built via flake
apps that shell out to `docker build` (their Dockerfiles land in Milestones
2-4, not here).

- [x] `flake.nix` with `packages.workspace-image` (real, via `dockerTools.buildLayeredImage`) and `apps.build-{workspace-mcp,chat-mcp,orchestrator}-image` (each shells out to `docker build` against that component's directory).
- [x] Per-component directory (`orchestrator/`, `workspace/`, `workspace-mcp/`, `chat-mcp/`) wired into the flake.
- [x] `apps.up` stubbed (prints "not implemented" — real implementation lands in Milestone 5).
- [x] `devShells.default` with `docker`, `docker-compose`, `python3` for local iteration.

**Definition of done:** `nix flake check` succeeds; `nix build .#workspace-image` produces a loadable image. (Verified on the developer's machine, which has Nix + Docker — this sandbox has neither.)

---

### Milestone 1 — Workspace container

**Goal:** a minimal, network-isolated container that can be `docker exec`'d into by hand.

- [x] Minimal base image + coreutils/shell (per `implementation.md`: enough for `echo`, `ls`, `cat` — not a full build toolchain yet).
- [x] No network (`docker run --network none` or Compose equivalent — confirm in Milestone 5's Compose file too).
- [x] No credentials, no MCP client, no inbound-listening process of any kind.

**Definition of done:** `docker run --network none --name axle-workspace <image> sleep infinity` starts it; `docker exec axle-workspace echo ok` works; `docker exec axle-workspace sh -c "curl -s example.com"` fails (no network path).

---

### Milestone 2 — Workspace MCP

**Goal:** the sole privileged container, exposing exactly one tool.

- [x] MCP server exposing `exec(command: string) -> {stdout, stderr, exit_code}` (`workspace-mcp/src/workspace_mcp/server.py`, `mcp` SDK's `MCPServer`/streamable-http transport).
- [x] Implementation is hardcoded to `docker exec <pre-configured-workspace-id> sh -c "<command>"` — container ID from `WORKSPACE_CONTAINER_ID` env, not a caller-supplied parameter.
- [x] No other docker subcommands reachable from the tool surface (no `run`, `rm`, `cp`, arbitrary socket access) — verified by reading the one `subprocess.run` call site.
- [x] Docker socket bind-mounted in at run time (Dockerfile only installs the `docker` CLI; the mount itself is Milestone 5's Compose concern) — this is the only container in the topology with that mount (grep the Compose file in Milestone 5 to confirm).
- [x] No internet egress configured for this container (network segmentation itself lands in Milestone 5's Compose file).

**Definition of done:** with Milestone 1's Workspace container running, an MCP client (a throwaway test script is fine here) can call `exec("echo hello")` and get back `{stdout: "hello\n", exit_code: 0}`; calling with a shell metacharacter payload still only ever reaches the one pre-configured container, never anything else on the host.
Verified in this session with a stubbed `docker` binary (argv construction, timeout/error paths, tool registration via `mcp.list_tools()`) — real `docker exec` behavior against a live Workspace container needs confirming on a machine with Docker.

---

### Milestone 3 — Chat MCP

**Goal:** a local chat surface, independently testable without the Orchestrator.

- [x] Small HTTP endpoint (Starlette/uvicorn) per ADR-0001 §6; container listens on `0.0.0.0` internally so Compose can publish it as `127.0.0.1:<port>:<port>` in Milestone 5 (host-only exposure is a Compose port-mapping concern, not something the process itself can enforce).
- [x] Token generated at container start (or pinned via `CHAT_MCP_TOKEN`); required via `TokenAuthMiddleware` on every endpoint including `/`.
- [x] `chat_send(message: string)` tool for the Orchestrator side, plus `chat_receive(timeout_seconds)` (poll-with-timeout) for messages the human sends in - both in `chat-mcp/src/chat_mcp/server.py`.
- [x] Minimal single-page web UI (`chat-mcp/src/chat_mcp/static/index.html`) that 1s-polls `/api/messages` and posts to `/api/send`.

**Definition of done:** starting the container prints a URL with the token in it; opening it in a browser shows a chat box; a message typed there is retrievable via the MCP-facing receive call (test with a stub script, since the Orchestrator isn't wired yet).
Verified in this session: ran the real server locally (Python available, no Docker needed for this), confirmed the web API (403 without token, send/poll round-trip) with `urllib`, and confirmed `chat_send`/`chat_receive` over real MCP streamable-HTTP transport with the `mcp` SDK's own client — a message posted via the web API was retrieved by `chat_receive`, and a reply sent via `chat_send` appeared in `/api/messages`. Container build itself (Dockerfile) needs `docker build` on a machine with Docker.

---

### Milestone 4 — Orchestrator

**Goal:** an `mcp-agent`-based harness with zero shell tools, wired to both MCP servers from Milestones 2 and 3.

- [x] `mcp-agent`'s `Agent` configured with exactly one MCP server in `server_names`: Workspace MCP (`mcp_agent.config.yaml`, server key `workspace`). Refinement vs. the original plan: Chat MCP is *not* given to the `Agent`/LLM as a callable server - `orchestrator/src/orchestrator/chat_client.py` talks to it directly with a raw MCP client instead, because waiting for human input and relaying the LLM's final reply is harness-level control flow, not something the LLM should decide to invoke mid-reasoning (see that file's docstring). The LLM's only callable tool is still exactly one: `workspace_exec`.
- [x] LLM provider configured per ADR-0001 §7: Anthropic, via `mcp_agent.config.yaml` (`default_model`) + `mcp_agent.secrets.yaml`/`ANTHROPIC_API_KEY` env (`mcp_agent.secrets.yaml.example` checked in as the template; the real file is gitignored).
- [x] `workspace_exec(command)` — confirmed by code inspection *and* by running it for real in this session: no local shell/subprocess call exists anywhere in the Orchestrator's own code (`orchestrator/src/orchestrator/` has none); mcp-agent namespaces Workspace MCP's `exec` tool as `workspace_exec` for the `workspace` server key, matching implementation.md's naming.
- [x] Chat loop in `orchestrator/src/orchestrator/main.py`: `ChatClient.receive()` polls Chat MCP (30s timeout, retry on `None`), the message goes to `llm.generate_str()` (with `workspace_exec` available to the LLM), the reply is relayed back via `ChatClient.send()` — wrapped in try/except so one failed turn doesn't kill the loop.
- [ ] Internet egress limited to the LLM provider's API/auth endpoints; internal network reaches Workspace MCP + Chat MCP only. (Network segmentation itself is Milestone 5's Compose file, not this milestone.)

**Definition of done:** with Milestones 1-3 running, starting the Orchestrator and sending it a chat message that requires no tool use gets a reply relayed back through Chat MCP.
Verified in this session, minus the actual LLM call (no Anthropic API key available in this sandbox): ran the real `MCPApp`/`Agent`/`ChatClient` stack locally against real (locally-run) Workspace MCP and Chat MCP servers. Confirmed `agent.list_tools()` shows exactly `["workspace_exec"]`, calling it executes a real command through the (stubbed-`docker`) exec path and returns real stdout, and `ChatClient.send()` delivers a message that shows up via Chat MCP's `/api/messages`. Also confirmed mcp-agent 0.2.6 requires `mcp<2` (it imports the pre-2.0 `mcp.server.fastmcp`/`streamablehttp_client` API) while workspace-mcp/chat-mcp use `mcp>=2` — each container's own isolated Python env makes this a non-issue, and a cross-version client/server interop check (mcp v1 client → mcp v2 server) passed. The one thing not exercised here is a real `generate_str()` call against the Anthropic API — needs `ANTHROPIC_API_KEY` on a machine that can reach it.

---

### Milestone 5 — Compose wiring and `apps.up`

**Goal:** one command brings up all four containers with the correct network segmentation.

- [x] `docker-compose.yml` (hand-written per ADR-0001 §4) defining:
  - Workspace: `network_mode: "none"`.
  - Workspace MCP: `internal: true` network shared with Orchestrator (no route to the outside world); `/var/run/docker.sock` bind mount; targets the Workspace container by its fixed `container_name`.
  - Chat MCP: `127.0.0.1:8787:8787` published (UI only) — the MCP port (8802) stays on the internal network only, reachable solely from the Orchestrator.
  - Orchestrator: `internal` network (reaching Workspace MCP + Chat MCP) + a separate `egress` network for internet access; no ports published, no volume mounts.
- [x] `apps.up` (`nix run .#up`) builds `workspace-image` via `nix build` + `docker load`, builds the other three via `docker build`, then runs `docker compose up`. Also added `build-{workspace-mcp,chat-mcp,orchestrator}-image` as standalone apps for iterating on one image at a time.
- [x] `restart: on-failure` on each service per ADR-0001 §4.

**Definition of done:** `nix run .#up` on a clean checkout brings up all four containers; `docker network inspect` confirms Workspace has no network attached and Workspace MCP/Chat MCP are not internet-reachable; only Orchestrator has an egress path out.
Not runnable in this sandbox (no Nix or Docker) — needs verifying on a machine with both, per the user's note that they'll check each milestone there. One thing worth double-checking on that machine: `docker-compose`'s `internal: true` network semantics can vary slightly by Compose/Docker version, so confirm egress is actually blocked, e.g. `docker compose exec chat-mcp python3 -c "import urllib.request; urllib.request.urlopen('https://example.com', timeout=3)"` should raise/timeout, not succeed.

---

### Milestone 6 — End-to-end validation (phase 1 exit criteria)

**Goal:** prove the full path named in phase 1's success criteria, as a repeatable check.

- [x] Runbook written: [phase-1-validation.md](phase-1-validation.md) — `nix run .#up` from a clean checkout, open the printed Chat MCP URL, send a message requiring a shell command, confirm the reply reflects real command output, then confirm containment (host-side check that the command really ran inside `axle-workspace`, and that network segmentation held).
- [x] Added a one-line audit log per `exec` call in Workspace MCP (`[workspace-mcp] exec exit=<code>: <command>`) so the runbook's containment check has something to point at (`docker compose logs workspace-mcp`) beyond trusting the reply text.
- [x] Walkthrough run for real on the developer's machine (Nix + Docker + a real `ANTHROPIC_API_KEY`). Hit and fixed a real bug along the way: `workspace-mcp`'s image was missing the `docker` CLI at runtime even though its Dockerfile's `apt-get install docker.io` reported success — Debian's `docker.io` package only ships the daemon (`dockerd`/`containerd`/`runc`); the actual `docker` binary lives in the separate `docker-cli` package, which is merely a `Recommends` of `docker.io` and so was silently dropped by `--no-install-recommends`. Fixed by installing `docker-cli` directly (see `workspace-mcp/Dockerfile`).
- [x] Core path confirmed live: sent chat messages requiring tool use, got real replies driven by real `workspace_exec` calls (not generic/refusal text) — the Orchestrator's LLM used `workspace_exec` to probe its own sandbox and correctly reported no DNS/outbound TCP/curl/wget/ping available, matching the Workspace container's `network_mode: none`. Satisfies runbook step 4 and, informally (from inside the container rather than the prescribed host-side `docker inspect`/`docker compose exec` checks), the spirit of step 2.
- [ ] Runbook steps 2 (host-side network segmentation checks), 3 (403-without-token check), 5 (host-side containment check via `docker exec axle-workspace` + `workspace-mcp` audit log), and 6 (no-op-turn survival) were not walked explicitly checkbox-by-checkbox in this session — worth a quick pass to close those out formally, though nothing in this session suggests they'd fail.

**Definition of done:** the walkthrough in phase-1-validation.md passes without manual workarounds, on a machine with Nix + Docker. Core path (steps 1 and 4) verified live; steps 2/3/5/6 still need an explicit pass to formally close this out.

---

## Explicitly deferred past phase 1

Per `implementation.md` and ADR-0001's follow-ups: additional MCP servers
(search, Git egress, artifact egress), MCP gateway/allowlist layer,
docker-socket-proxy in front of Workspace MCP, multi-agent/multi-workspace
scenarios, MicroVM-backed runtime. None of these block the Milestone 6 exit
criteria and should not be pulled forward into phase 1 scope.
