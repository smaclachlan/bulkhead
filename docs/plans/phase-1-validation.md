# Phase 1 Validation Runbook

Walks through [phase-1-implementation-plan.md](phase-1-implementation-plan.md)'s
Milestone 6 exit criteria: prove that a human, talking only through the Chat
MCP's local URL, can get the Orchestrator's LLM to run a command that
executes *only* inside the network-isolated Workspace container, with the
result relayed back to the chat UI.

**Automated harness:** `scripts/validate-phase1.sh` runs every check below
against a live `nix run .#up` stack and writes a timestamped, structured
result record to `validation-results/phase-1/` (plus `latest.json`) — a
durable attestation trail of when this was checked and what held, not just a
pass/fail shown once in a terminal. Prefer it over the manual walkthrough
below for repeat runs; see `validation-results/README.md` for the record
schema and how to extend this for a later phase.

The harness also runs a **step 7**, beyond this manual runbook's original
scope: direct MCP-protocol checks against `workspace-mcp`'s `/mcp` endpoint,
bypassing the chat/LLM path entirely - confirms it's unreachable from the
host, that it exposes exactly one tool (`exec`) with a schema that only
takes `command` (no hidden target-selection field), that a raw exec call
actually runs inside the Workspace container, that `docker ps` fails inside
it (no docker CLI there), and - honestly, not assuming the ADR's intent
holds - whether `chat-mcp` can reach `workspace-mcp` over their shared
`internal` network even though [ADR-0001 §1](../adr/0001-phase-1-four-container-architecture.md)
says it should be reachable from the Orchestrator only. `internal: true`
blocks egress to the outside world, but doesn't isolate members of the same
network from each other - if this check fails, that's real information
about a phase-1 gap, not something to explain away.

**Status: core path run for real** (steps 1, 3 and 4 below, plus two of
step 5's three containment checks), on the developer's machine with Nix +
Docker + a real `ANTHROPIC_API_KEY` - this first pass was manual, before the
harness existed. Step 2's host-side network checks, the one remaining step 5
check (an operator-run, independent `docker exec` re-read), and step 6 are
covered by the harness but not yet confirmed by an actual run of it - see
`validation-results/phase-1/` for whether that's happened yet. The
checkboxes below are kept as a narrative record of the manual first pass;
the harness is the source of truth going forward.

Getting here surfaced a real bug: `workspace-mcp`'s image built successfully
(`apt-get install docker.io` reported exit 0) but had no `docker` binary at
runtime, because Debian's `docker.io` package only ships the daemon
(`dockerd`/`containerd`/`runc`) - the `docker` CLI itself lives in the
separate `docker-cli` package, which is only a `Recommends` of `docker.io`
and so was silently dropped by `--no-install-recommends`. Fixed by installing
`docker-cli` directly instead (`workspace-mcp/Dockerfile`).

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

   - [x] All four containers report healthy/running (no crash-loop in the logs).
   - [ ] The `chat-mcp` logs print a line like `[chat-mcp] chat UI: http://localhost:8787/?token=...`. (Chat UI was reached and used successfully; this specific log line wasn't explicitly checked.)

2. **Confirm network segmentation before doing anything else** (fail fast if this is wrong - no point validating the happy path on a leaky sandbox):
   - [ ] `docker inspect bulkhead-workspace --format '{{.HostConfig.NetworkMode}}'` → `none`. Not run explicitly this pass, but see step 4: the Orchestrator's LLM independently probed this from inside the container via `workspace_exec` (DNS, outbound TCP, curl/wget/ping all confirmed absent), consistent with this holding.
   - [ ] `docker compose exec chat-mcp python3 -c "import urllib.request; urllib.request.urlopen('https://example.com', timeout=3)"` → fails/times out (chat-mcp has no egress).
   - [ ] `docker compose exec workspace-mcp python3 -c "import urllib.request; urllib.request.urlopen('https://example.com', timeout=3)"` → fails/times out (same).
   - [ ] Only `orchestrator` can reach the internet (it needs to, for the Anthropic API — no direct test needed here since step 4 exercises it for real).

3. **Open the chat UI.** Paste the URL from step 1 into a browser.
   - [x] The page loads and shows an empty chat log and a message box.
   - [x] Loading `http://localhost:8787/` **without** the token query param returns 403, not the page (confirms the auth gate is live, not just present in code). Confirmed in practice: the bare URL doesn't work, only the printed link with the token does.

4. **Send a message that requires a command.** E.g.: `What files are in the workspace right now? Also create a file called hello.txt with the text "bulkhead works" in it, then show me its contents.`
   - [x] A reply appears in the chat UI within a reasonable time (no manual polling/refresh needed beyond the page's own 1s poll).
   - [x] The reply's content is consistent with a real command having run — confirmed two ways: (1) a network-probing prompt ("can you access container now?" / "can you search the internet?"), where the LLM used `workspace_exec` to run real commands inside the Workspace container (DNS/TCP/curl/wget/ping checks) and reported real, non-generic results; (2) the runbook's own suggested prompt, where the LLM used `workspace_exec` with `echo` to create `hello.txt` and `cat` to read it back, and relayed the real file contents in its reply.

5. **Confirm containment held during step 4**, not just that it worked:
   - [ ] `docker exec bulkhead-workspace sh -c "cat hello.txt"` on the host shows the file the agent created — proving the command really executed *inside* the Workspace container, not somewhere else. The agent itself used `workspace_exec` with `cat` to read the file back and relayed real contents in its reply, which is suggestive but not independent — still worth an operator-run `docker exec` to confirm the agent wasn't just repeating what it wrote without truly re-reading it.
   - [x] `docker compose logs workspace-mcp` (or `docker logs bulkhead-workspace-mcp-1`) shows the corresponding `docker exec` call — confirmed, e.g. `[workspace-mcp] exec exit=0: 'echo "hello" > hello.txt && cat hello.txt && pwd && ls -la hello.txt'`. Note: `bulkhead-workspace` itself shows zero logs, which is expected, not a bug — `docker exec` output is a separate session, never written to the target container's own log stream; the audit trail is `workspace-mcp`'s printed line, by design (see Milestone 6).
   - [x] Nothing outside `bulkhead-workspace` was touched — confirmed no `hello.txt` (or equivalent) landed on the host filesystem.

6. **Confirm the loop survives a no-op turn.** Send a message needing no tool use (e.g. `hi`) and confirm a reply comes back without the Orchestrator process restarting (`docker compose ps` shows the same container, not a fresh restart count).
   - [ ] Not explicitly tested with a no-tool-use message, though the loop did survive across multiple consecutive tool-using turns in the same session.

## If something fails

- **Orchestrator can't reach `workspace-mcp`/`chat-mcp` by hostname** — confirm all three are on the `internal` Compose network (`docker network inspect <project>_internal`).
- **`workspace-mcp` can't `docker exec` into `bulkhead-workspace`** — confirm the socket bind mount (`docker inspect bulkhead-workspace-mcp` → `Mounts`) and that `WORKSPACE_CONTAINER_ID=bulkhead-workspace` matches the Workspace service's `container_name` in `docker-compose.yml`.
- **Chat UI shows 403 even with the token** — the token in the printed URL must match `CHAT_MCP_TOKEN` if you pinned one in `.env`; if you didn't, use the one Chat MCP generated and printed, not a stale one from a previous run.
- **`generate_str` errors out** — check `ANTHROPIC_API_KEY` is set and valid; the Orchestrator's try/except (see `orchestrator/src/orchestrator/main.py`) should relay the error text into the chat instead of crashing, which is itself worth confirming. Confirmed in practice: without a valid key, chat doesn't function — `ANTHROPIC_API_KEY` is a hard requirement, not optional.
- **`docker logs bulkhead-workspace` shows nothing** — expected, not a failure. `docker exec` output never lands in the target container's own log stream; check `docker compose logs workspace-mcp` instead for the `[workspace-mcp] exec exit=<code>: <command>` audit lines.

## Definition of done

All checkboxes above pass on one run, from a clean `nix run .#up`, without manual workarounds. This closes phase 1 per
[phase-1-implementation-plan.md](phase-1-implementation-plan.md)'s top-level
definition of done. **Core path verified live (steps 1, 3, 4, and two of
three step 5 checks); step 2's host-side network checks, step 5's last
independent-verification check, and step 6 still need an explicit pass** —
tagged `phase-1-proof-of-concept` on the strength of the core path holding,
not a full formal close-out.

## Follow-ups noticed while writing this runbook (not phase 1 blockers)

- ~~Step 5 assumes `workspace-mcp` logs each `exec` call it makes~~ — added (`[workspace-mcp] exec exit=<code>: <command>`, see Milestone 6).
- ~~No automated version of this runbook exists yet~~ — `scripts/validate-phase1.sh` now runs the full checklist and stores results under `validation-results/phase-1/`.
