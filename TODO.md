# TODO

Ordered easiest → hardest to execute.

- [mostly done] Drop privileges of all containers - currently all root
  Done: workspace-mcp, chat-mcp, orchestrator, memory-mcp and workspace
  (the default Nix image) all run as non-root now. The first four got
  `USER` in their Dockerfiles (memory-mcp's /data also chowned before
  `VOLUME` so the named volume seeds writable). workspace's default image
  (workspace/default.nix) got `User = "10001:10001"` plus a
  `fakeRootCommands` block that pre-owns `/repo` and sets `HOME=/repo` -
  self-contained to that one file, so `WORKSPACE_DOCKERFILE_DIR` custom
  profiles are untouched and can still run as root if their tooling needs
  it. Belt-and-braces rather than load-bearing there - this container's
  real containment is no network + optional Kata microVM, not the UID -
  and it only covers the default `WORKSPACE_REPO_PATH` (`/repo`); a
  custom path would need its own chown.
  NOT changed, deliberately:
    - git-mcp: docker-compose.yml already documents why (search
      "Still runs as root" in that file) - dropping ALL capabilities was
      tried and reverted because it also strips CAP_DAC_OVERRIDE, which
      root needs to read the bind-mounted deploy key when its host-side
      owner isn't UID 0. A non-root user here needs the deploy key's host
      file ownership sorted out first (or a narrower cap_drop than ALL) -
      real follow-up, not a drive-by change.
    - docker-socket-proxy: third-party image (tecnativa/docker-socket-proxy)
      that still proxies the live Docker socket. Forcing a `user:` override
      without being able to verify against a running daemon (no docker
      available in the environment this change was made in) risks silently
      breaking the one path `exec` depends on. Needs testing with
      `nix run .#up` before touching.
  Not yet done for any of the five changed images: verifying the stack
  actually still comes up (`nix run .#up` / `nix run .#validate-phase1`
  or similar) - no docker/nix in this environment, so these changes are
  unverified, workspace's `fakeRootCommands`/`enableFakechroot` build path
  especially. Run the stack's validation before relying on this.

- Investigate using Claude Code in the orchestrator instead of MCP-Agent
  orchestrator/ currently pins `mcp<2` specifically because `mcp-agent`
  0.2.x hasn't moved to the v2 SDK shape (see the pin comment in
  orchestrator's deps and docs/adr/0001 on per-container isolated envs).
  That's a live maintenance cost. This is a research spike, not a build:
  compare what mcp-agent gives today (orchestration, multi-server routing)
  against driving Claude Code directly, and write up the tradeoff. Low
  effort to scope, but the outcome could mean a real rewrite of
  orchestrator/src/orchestrator/main.py.

- Easy switching between models/agents - list of supported backends?
  Today .env.example only wires a single `ANTHROPIC_API_KEY` for the
  orchestrator's LLM calls - no model selection surface exists at all.
  Bounded scope: add a config/env var for model id, thread it through
  wherever the Anthropic client is constructed, expose it in the chat UI.
  No architectural blockers, just needs the client construction point(s)
  found and parameterized.

- Make the whole MCP system more modular? Is this possible as we are
  locking down MCP's more...
  Already scoped in docs/plans/phase-2-mcp-gateway-investigation.md
  (ADR-0002 Decision 5). Conclusion there: a full gateway (ToolHive etc.)
  fights Bulkhead's per-container isolation model, but tool-surface
  allowlisting is a real, narrower gap - nothing currently checks that
  workspace-mcp still exposes exactly `exec` or that memory-mcp's nine
  tools match what ADR-0002 Decision 4 named, other than a manual step in
  `scripts/validate-phase1.sh`. Next step is turning that manual check
  into an automated startup/CI assertion rather than inventing a new
  design.

- Batch or concurrent commands from agent to Workspace? Look at speeding
  up commands/multiple agents running at once
  workspace-mcp's `exec` tool (workspace-mcp/src/workspace_mcp/server.py)
  runs one `docker exec` subprocess per call, synchronously, against a
  single pre-configured Workspace container - no batching, no concurrency
  today. Needs care: overlapping execs in the same container share
  filesystem/process state, so this is as much a correctness question
  (what happens when two agents write the same file at once) as a
  performance one. Medium effort - the change is contained to one file,
  but the concurrency semantics need actual design.

- Add skills support (.claude etc)
  No existing skills/plugin surface in the repo to extend - this is new
  ground. Needs a decision on what "skills" means for Bulkhead's model
  (loaded into the orchestrator? exposed as MCP tools? synced into the
  Workspace container?) before implementation starts. Higher effort
  because the design question is still open.

- Improve chat interface to be more like Claude Code CLI
  chat-mcp/src/chat_mcp/ is a small Starlette app (web.py, static/index.html)
  with a bearer-token gate (auth.py) - functional but minimal. "More like
  the CLI" is a broad, somewhat undefined target (streaming tool-call
  display? transcript history? slash commands?) so this needs scoping into
  concrete deliverables before it's a sized task, not just a straight
  build.

- Editor integration - VSCode or similar?
  No existing integration surface for this - would mean a new VSCode
  extension project talking to chat-mcp/orchestrator over a new or
  adapted protocol. Large, mostly-greenfield effort with its own release/
  packaging surface outside this repo's current stack.

- Claude OAUTH... Will this be possible?
  Open feasibility question, not just an implementation task - depends on
  what Anthropic's OAuth support actually allows for a non-first-party
  client like this. Blocked on research outside the repo before any
  scoping is possible; likely the hardest to size let alone execute.
