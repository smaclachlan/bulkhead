# ADR-0001: Four-Container Architecture for Phase 1

- Status: Proposed
- Date: 2026-09-19
- Supersedes: none
- Related: [README.md](../../README.md), [implementation.md](../../implementation.md), [Phase 1 Implementation Plan](../plans/phase-1-implementation-plan.md)

## Context

Axle's goal (README.md) is a sandbox that keeps an LLM-driven agent contained:
no direct shell access from the Orchestrator, a network-isolated Workspace that
can only be reached through one narrow, privileged exec path, and every other
capability mediated by a strictly-scoped MCP server.

`implementation.md` already scopes the first buildable milestone down to four
containers and a specific division of responsibility between them, in order to
prove the core containment path — Orchestrator -> Workspace MCP -> `docker exec`
-> Workspace, plus a human chat surface — before any other MCP server (search,
Git egress, artifact egress) is added.

This ADR exists to:
1. Formalize that four-container shape as a decision, not just a scoping note,
   so later phases have a clear baseline to extend or deviate from deliberately.
2. Resolve the items `implementation.md` left under "Not Yet Decided" enough to
   start building phase 1, while keeping them cheap to revisit.

## Decision

Build phase 1 as four independently-built, independently-networked containers,
composed together, with the following v1 answers to the previously open
questions:

### 1. Topology (four containers, as scoped)

| Container | Network | Holds | Exposes |
|---|---|---|---|
| Orchestrator | Internet egress only (LLM provider + auth) | LLM client (`mcp-agent`), zero shell tools | Nothing inbound; only calls out to Workspace MCP + Chat MCP over the internal network |
| Workspace | None | Build/dev tooling | Nothing — pure `docker exec` target, no MCP client of its own |
| Workspace MCP | Internal-only, reachable from Orchestrator only | Docker socket (the *only* container with this mount) | One tool: `exec(command) -> {stdout, stderr, exit_code}` hardcoded to a single pre-configured Workspace container ID |
| Chat MCP | Bound to `127.0.0.1` only | Chat session state | `chat_send` / receive mechanism to the Orchestrator; local web UI for the human |

This mirrors README cornerstones 1-5 point-for-point: least privilege per
container, Orchestrator has no Bash/CLI, Workspace is unreachable except via
the docker-exec proxy, and that proxy is the sole holder of the Docker socket.

### 2. Orchestrator harness: `mcp-agent`

Chosen specifically because it ships with **no built-in tools** — no bash, no
file I/O — so "MCP-only" is a property of the framework, not a configuration
we have to maintain by omission. Shell-shaped requests become one forwarding
MCP tool (`workspace_exec`) that relays to Workspace MCP; the Orchestrator
process itself never executes anything.

**Refinement made during implementation:** the LLM is only ever given
*Workspace* MCP as an attached server (`Agent(server_names=["workspace"])`);
Chat MCP is reached by a small hand-rolled MCP client in the harness code
itself (`orchestrator/chat_client.py`), not exposed to the LLM as a callable
tool. Waiting for the next human message and relaying the LLM's final reply
back is harness-level control flow — the LLM should not be able to decide,
mid-reasoning, to call `chat_send` an arbitrary number of times with
arbitrary text. This keeps the LLM's only callable tool surface to exactly
one tool (`workspace_exec`), which is a strictly narrower reading of
cornerstone 2 than "attach both MCP servers to the Agent" would have been.

### 3. Build system: Nix flake, one derivation per image

Each container is its own Nix output (`packages.orchestrator-image`,
`packages.workspace-image`, `packages.workspace-mcp-image`,
`packages.chat-mcp-image`) so an image can only contain what that component
needs by construction (e.g. Workspace MCP's image has no LLM client in it).

**Resolving "exact Nix packaging approach" (previously open), decided per
container rather than uniformly:**

- **Workspace** has no application dependencies (coreutils + a shell) and
  builds cleanly as a pure `pkgs.dockerTools.buildLayeredImage` package
  (`packages.workspace-image`) — no Dockerfile, no network needed at build
  time, reproducible from the nixpkgs pin alone.
- **Workspace MCP, Chat MCP, Orchestrator** are Python services with real
  third-party dependencies (`mcp`, `mcp-agent`, etc.). Packaging Python
  dependency trees as pure, sandboxed Nix derivations is its own unsolved
  yak-shave (poetry2nix/mach-nix-class tooling) that would block phase 1 on
  packaging problems unrelated to proving the containment path. Each of these
  three keeps a plain `Dockerfile` + pinned `requirements.txt` as the actual
  build recipe, and the flake exposes a `nix run .#build-<name>-image` app
  that shells out to `docker build` against that Dockerfile. This is
  `implementation.md`'s named alternative ("Nix only producing reproducible
  build scripts around plain Dockerfiles"), applied to just the three
  Python containers — it works because a flake `app` runs on the host at
  `nix run` time with full network/daemon access, unlike a `packages.*`
  derivation, which is sandboxed and must stay pure.

This is a reversible, per-image choice: nothing about a container's external
API or network boundary depends on which of the two build paths produced its
image. Revisit pure-Nix Python packaging once phase 1's containment path is
proven, if reproducibility of the Python images becomes a real pain point.

### 4. Process supervision: Docker Compose, generated by Nix

**Resolving "process supervision / restart policy" (previously open):** use
Docker Compose for phase 1 (`apps.up` generates or shells out to a
`docker-compose.yml` derived from the Nix flake), rather than
systemd/launchd units. Rationale: Compose's network/volume/mount declarations
map directly onto the segmentation this ADR requires (internal-only network
for Workspace MCP + Chat MCP's Orchestrator-facing side, no network for
Workspace, Docker-socket bind mount scoped to Workspace MCP only), it's
cross-platform for the Docker-backend case, and it keeps restart-policy
concerns (`restart: on-failure`) declarative and reviewable in one file rather
than per-OS unit files. MicroVM-backed platforms (README's longer-term Nix/
MicroVM direction) can replace this later without changing the container
boundaries this ADR defines.

### 5. Workspace MCP's Docker socket access: raw socket for v1

**Resolving "raw socket vs. scoped docker-socket-proxy" (previously open):**
mount `/var/run/docker.sock` directly into Workspace MCP for phase 1, guarded
by Workspace MCP's own tiny hardcoded API surface (one `exec` tool, one
pre-configured container ID, no other docker subcommands reachable). A scoped
proxy (e.g. `docker-socket-proxy`) is deferred, not rejected — it's a
defense-in-depth layer worth adding once phase 1's exec path is proven, tracked
as a phase 2 follow-up (README's Further Threats item 2, supply-chain/blast
radius). Shipping it now would add a second thing to debug before the core
path is even proven end-to-end.

### 6. Chat MCP auth: bearer token in the local URL for v1

**Resolving "auth/token story for Chat MCP" (previously open):** generate a
random token at container start, require it as a query param or header on the
chat endpoint (`http://localhost:8787/?token=...`). This is deliberately
minimal — the threat it addresses is another local process/user on the same
host reading the conversation, not a network attacker (the port is already
`127.0.0.1`-bound). Full session auth (accounts, rotating tokens) is out of
scope until there's a multi-user or remote-access story.

### 7. LLM provider for phase 1 validation: whichever is fastest to wire up

`mcp-agent`'s provider config should support both API-key and OAuth-based
providers per `implementation.md`; phase 1 only needs *one* working provider
to validate the path end-to-end. Default to whichever the developer already
has credentials for (Claude or OpenAI) rather than building both — provider
abstraction is `mcp-agent`'s job, not something phase 1 needs to prove twice.

## Consequences

**Positive**
- Every containment property in README's cornerstones 1-5 is testable
  directly against phase 1's four containers — there's no "trust us, phase 2
  will add the isolation" gap.
- Each open question resolved above is independently reversible: swapping
  Compose for systemd units, or the raw socket for a proxy, doesn't change any
  container's external API or network boundary.
- Nix-per-image keeps the least-privilege intent enforceable by build
  tooling rather than by code review vigilance alone.

**Negative / accepted risk**
- Raw Docker socket mount (even scoped to one container) is a known-sharp
  edge; a bug in Workspace MCP's own code is a larger blast radius than it
  would be behind a proxy. Accepted for phase 1 in exchange for not debugging
  two new pieces of privileged infrastructure at once; tracked as a phase 2
  follow-up.
- Compose is a lighter supervision story than the MicroVM direction floated
  in README — acceptable because phase 1's goal is proving the containment
  *shape*, not the final production runtime.
- Four separate Nix image derivations is more moving parts than a single
  container up front; accepted because it's the only way to make "Workspace
  MCP's image has no LLM client" a build-time guarantee rather than a
  Dockerfile-hygiene convention.

**Follow-ups tracked for later phases (not phase 1 scope)**
- Docker-socket-proxy in front of Workspace MCP.
- MicroVM-backed runtime in place of/alongside Docker.
- MCP gateway/allowlist layer (e.g. ToolHive) once more than one downstream
  MCP server exists.
- Git MCP and artifact egress (README's Egress section) — explicitly excluded
  from phase 1 per `implementation.md`.

## Alternatives Considered

- **Single container running everything.** Rejected outright — it collapses
  every isolation boundary this project exists to prove; not a real
  alternative given the threat model in README.
- **Kubernetes instead of Compose for phase 1 supervision.** Rejected for now
  as disproportionate operational overhead for a four-container local-first
  milestone; revisit if Axle needs multi-host or multi-tenant scheduling.
- **Scoped docker-socket-proxy from day one instead of the raw socket.**
  Considered and deferred rather than rejected (see Decision #5) — it's
  additive later without changing Workspace MCP's external API.
- **Building a custom Orchestrator harness instead of `mcp-agent`.** Rejected
  for phase 1: `mcp-agent`'s "no built-in tools" property gives the
  MCP-only guarantee for free; a custom harness would have to re-earn that
  guarantee through code review every time it changes.
