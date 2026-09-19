# Pandora - Implementation Details (v1 Milestone)

# Scope
This document scopes the first buildable milestone against the design intent in README.md: prove the Orchestrator -> Workspace MCP -> Workspace exec path, plus a basic human chat surface, before any other MCP servers (web search, Git egress, artifact egress) are added. Limited to four containers:
1. Orchestrator
2. Workspace
3. Workspace MCP
4. Chat Interface MCP

# Nix-based Initialisation
- Nix (flake) is the single source of truth for building each container image, so the four containers are reproducible across machines rather than hand-maintained Dockerfiles drifting apart.
- Each container gets its own Nix derivation/output so its image only contains what that component needs - keeps the least-privilege intent from README point-for-point (e.g. Workspace MCP's image should not contain an LLM client, Orchestrator's image should not contain a shell).
- Proposed flake shape (naming indicative, not final):
    - `packages.orchestrator-image`
    - `packages.workspace-image`
    - `packages.workspace-mcp-image`
    - `packages.chat-mcp-image`
    - `apps.up` - composes/starts all four with the correct network segmentation and socket/volume mounts (docker compose generated from Nix, or a Nix-driven `docker run` script - to be decided)
- Open question: full OCI images built via Nix (`dockerTools.buildImage`) vs Nix only producing reproducible build scripts around plain Dockerfiles. Revisit once the four-container skeleton runs at all.

# Container: Orchestrator
Purpose: the LLM-facing harness - the "brain" that talks JSON to the cloud LLM and decides which MCP tool to call.

- Built on **mcp-agent** as the host orchestration mechanic. Chosen specifically because it ships with no built-in tools (no bash, no file I/O) - it is a blank slate you wire MCP servers into, so "MCP-only" is true by construction rather than something to strip out or configure away.
- Network: internet egress required, for two things only:
    1. LLM provider API calls (Claude, OpenAI, etc.)
    2. Provider auth flows - both OAuth (e.g. Claude subscription login) and API-key based providers should be supported via mcp-agent's provider config (`mcp_agent.secrets.yaml` / env vars).
- Zero local Bash/CLI: no shell tool is registered on the Orchestrator's tool set, ever. All the Orchestrator can do is call out to the two MCP servers configured for this milestone:
    - Workspace MCP, for anything shell/bash-shaped
    - Chat Interface MCP, for anything human-facing
- Shell routing: a shell/bash-shaped request from the LLM is implemented as a single MCP tool, e.g. `workspace_exec(command: string) -> {stdout, stderr, exit_code}`, whose implementation on the Orchestrator side is nothing but a forwarding call to Workspace MCP over MCP. The Orchestrator process itself never runs the command; it only relays it.
- Internal network: also needs to reach Workspace MCP and Chat Interface MCP over an internal-only network (no need for either of those to be internet-reachable from the Orchestrator's side).

# Container: Workspace
Purpose: the actual sandbox where code/build tooling lives - what the agent is working on.

- Network: **none**. Fully network-isolated per README point 4 - no route in or out except `docker exec`.
- Access: the *only* way in is `docker exec` issued by the Workspace MCP container, which alone holds the Docker socket. The Workspace container has no MCP client of its own and is not itself a participant in the MCP graph - it is a pure exec target.
- v1 contents: minimal base image plus basic Linux tools (shell, coreutils, and enough to sanity-check the pipeline - e.g. `echo`, `ls`, `cat`). The goal for this milestone is proving Orchestrator -> Workspace MCP -> `docker exec` -> Workspace end-to-end works, not standing up a full build toolchain yet. Full build environments (README point 7) come after this skeleton is proven.
- No credentials of any kind should live in this container - it has no network path to use them on anyway, but it should also never be handed any, on the assumption that isolation is defense-in-depth, not the only layer.

# Container: Workspace MCP
Purpose: the sole privileged component - the one place the host Docker socket is reachable from.

- Docker socket: bind-mounted in (`/var/run/docker.sock`). This should be the *only* container in the topology with this mount.
- API surface is deliberately tiny: one tool, `exec(command: string) -> {stdout, stderr, exit_code}`, hardcoded to run `docker exec <workspace-container-id> sh -c "<command>"` against a single, pre-configured Workspace container ID.
    - No parameter to choose an arbitrary target container.
    - No other docker subcommands exposed (no `docker run`, `docker rm`, `docker cp`, etc. in this milestone - `docker cp` for build-artifact egress is a separate, later, narrowly-scoped tool per README's Egress section, not bundled into this one).
- Network: internal-only, reachable solely from the Orchestrator. No internet egress needed for this container at all.
- No agent/LLM logic here by design - it is a dumb proxy/executor. Keeping it dumb keeps its trusted-code surface small enough to audit by hand.
- Open question: whether to put a scoped docker-socket-proxy in front of the raw socket even at this stage, rather than mounting it directly, to reduce what a bug in this container's own code could still reach on the host.

# Container: Chat Interface MCP
Purpose: give the human operator a channel to the Orchestrator/LLM - the "Chat to CLI interface" from the design intent, delivered as a local chat surface for v1.

- Network: local-only exposure, e.g. bound to `127.0.0.1` with a small web UI or HTTP/WebSocket endpoint (`http://localhost:8787` or similar, exact port TBD). Not reachable from outside the host.
- Acts as an MCP server from the Orchestrator's perspective: exposes something like `chat_send(message: string)` plus a receive-side mechanism (poll or push) so the Orchestrator only ever reaches the human through this MCP, never via a raw stdout/stdin channel.
- The human <-> Orchestrator direction is expected to stay freeform text - a human is on the other end, and this is also the natural place for the human-approval step (e.g. confirming a Git push) to surface once that MCP exists. The narrowest-vocabulary principle (README cornerstone 9) applies to any *automated* status/notification traffic this component might carry later, not to the live human chat itself.
- Open question: whether v1 needs any local auth (e.g. a token in the URL) to stop another local process/user on the same machine from reading the conversation, even though it's not internet-exposed.

# Not Yet Decided
- Process supervision / restart policy for the four containers (docker compose, a Nix-generated systemd/launchd unit set, or manual scripts) for this milestone.
- Whether Workspace MCP's Docker socket access is the raw socket or a scoped proxy from day one.
- Exact Nix packaging approach for the four images (see Nix-based Initialisation above).
- Auth/token story for the Chat Interface MCP's local endpoint.

# Explicitly Out of Scope for This Milestone
- Any additional MCP servers (search, Git egress, artifact egress, Slack or other messaging integrations).
- MCP gateway/allowlist layer (e.g. ToolHive) in front of Workspace MCP or Chat Interface MCP - worth adding once there is more than one downstream MCP server to police.
- Multi-agent / multi-workspace scenarios.
