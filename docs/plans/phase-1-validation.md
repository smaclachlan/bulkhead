# Phase 1 Validation Runbook

Walks through [phase-1-implementation-plan.md](phase-1-implementation-plan.md)'s
Milestone 6 exit criteria: prove that a human, talking only through the Chat
MCP's local URL, can get the Orchestrator's LLM to run a command that
executes *only* inside the network-isolated Workspace container, with the
result relayed back to the chat UI.

This has not been run end-to-end yet - it needs a machine with Nix and
Docker (this repo's own development sandbox had neither when Milestones 0-5
were built; the pieces were verified individually instead - see each
milestone's "Definition of done" note in the implementation plan for exactly
what was and wasn't exercised).

## Prerequisites

- [ ] Nix (flakes enabled) and Docker installed and running.
- [ ] `cp .env.example .env` and fill in `ANTHROPIC_API_KEY`. Leave `CHAT_MCP_TOKEN` blank to let Chat MCP generate one (it'll be in the logs).
- [ ] Run everything from the repo root (`flake.nix` and `docker-compose.yml` must be in `$PWD` — see flake.nix's `apps.up`/`apps.build-*` comments).

## Steps

1. **Bring the stack up.**
   ```
   nix run .#up
   ```
   Expect: Nix builds `workspace-image`, `docker load`s it, `docker build`s
   the other three images, then `docker compose up` starts all four and
   streams logs.

   - [ ] All four containers report healthy/running (no crash-loop in the logs).
   - [ ] The `chat-mcp` logs print a line like `[chat-mcp] chat UI: http://localhost:8787/?token=...`.

2. **Confirm network segmentation before doing anything else** (fail fast if this is wrong - no point validating the happy path on a leaky sandbox):
   - [ ] `docker inspect pandora-workspace --format '{{.HostConfig.NetworkMode}}'` → `none`.
   - [ ] `docker compose exec chat-mcp python3 -c "import urllib.request; urllib.request.urlopen('https://example.com', timeout=3)"` → fails/times out (chat-mcp has no egress).
   - [ ] `docker compose exec workspace-mcp python3 -c "import urllib.request; urllib.request.urlopen('https://example.com', timeout=3)"` → fails/times out (same).
   - [ ] Only `orchestrator` can reach the internet (it needs to, for the Anthropic API — no direct test needed here since step 4 exercises it for real).

3. **Open the chat UI.** Paste the URL from step 1 into a browser.
   - [ ] The page loads and shows an empty chat log and a message box.
   - [ ] Loading `http://localhost:8787/` **without** the token query param returns 403, not the page (confirms the auth gate is live, not just present in code).

4. **Send a message that requires a command.** E.g.: `What files are in the workspace right now? Also create a file called hello.txt with the text "pandora works" in it, then show me its contents.`
   - [ ] A reply appears in the chat UI within a reasonable time (no manual polling/refresh needed beyond the page's own 1s poll).
   - [ ] The reply's content is consistent with a real command having run (e.g. it names actual files, or otherwise shows real tool output rather than a generic "I can't do that" response).

5. **Confirm containment held during step 4**, not just that it worked:
   - [ ] `docker exec pandora-workspace sh -c "cat hello.txt"` on the host shows the file the agent created — proving the command really executed *inside* the Workspace container, not somewhere else.
   - [ ] `docker compose logs workspace-mcp` shows the corresponding `docker exec` call (or add temporary logging if it doesn't yet — see follow-up below).
   - [ ] Nothing outside `pandora-workspace` was touched — there's no equivalent `hello.txt` on the host filesystem or in any other container.

6. **Confirm the loop survives a no-op turn.** Send a message needing no tool use (e.g. `hi`) and confirm a reply comes back without the Orchestrator process restarting (`docker compose ps` shows the same container, not a fresh restart count).

## If something fails

- **Orchestrator can't reach `workspace-mcp`/`chat-mcp` by hostname** — confirm all three are on the `internal` Compose network (`docker network inspect <project>_internal`).
- **`workspace-mcp` can't `docker exec` into `pandora-workspace`** — confirm the socket bind mount (`docker inspect pandora-workspace-mcp` → `Mounts`) and that `WORKSPACE_CONTAINER_ID=pandora-workspace` matches the Workspace service's `container_name` in `docker-compose.yml`.
- **Chat UI shows 403 even with the token** — the token in the printed URL must match `CHAT_MCP_TOKEN` if you pinned one in `.env`; if you didn't, use the one Chat MCP generated and printed, not a stale one from a previous run.
- **`generate_str` errors out** — check `ANTHROPIC_API_KEY` is set and valid; the Orchestrator's try/except (see `orchestrator/src/orchestrator/main.py`) should relay the error text into the chat instead of crashing, which is itself worth confirming.

## Definition of done

All checkboxes above pass on one run, from a clean `nix run .#up`, without manual workarounds. This closes phase 1 per
[phase-1-implementation-plan.md](phase-1-implementation-plan.md)'s top-level
definition of done.

## Follow-ups noticed while writing this runbook (not phase 1 blockers)

- Step 5 assumes `workspace-mcp` logs each `exec` call it makes; the current implementation (`workspace-mcp/src/workspace_mcp/server.py`) doesn't log anything beyond uvicorn's own request log. Worth adding a one-line log per `exec` call (command, exit code) for auditability — small, but out of scope for getting the skeleton running.
- No automated version of this runbook exists yet (it's a manual checklist). Worth scripting once phase 2 needs repeatable CI-style validation rather than by-hand checks.
