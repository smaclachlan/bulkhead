# TODO

Ordered easiest → hardest to execute.

- Drop privileges of all containers - currently all root
  No `user:` directive on any service in docker-compose.yml, so
  workspace/workspace-mcp/memory-mcp/git-mcp/chat-mcp/orchestrator all run
  as root by default. Fix is mechanical: add non-root `user:`/`USER` per
  image, then re-check bind-mount and volume ownership (workspace's
  git/build dirs especially) still work. Self-contained, no design
  decisions, good first PR.

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
