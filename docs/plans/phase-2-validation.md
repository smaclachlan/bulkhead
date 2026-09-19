# Phase 2 Validation Runbook

Verifies the three headline claims [ADR-0002](../adr/0002-phase-2-isolation-ux-memory.md)
makes about phase 2, per Stuart's own framing for that ADR: improved chat
UX, tighter isolation via Kata + docker-socket-proxy, and memory that
survives across sessions - not just that the code merged. See ADR-0002's
own "Testing & Validation" section for the reasoning behind each check
below.

**Automated harness:** `scripts/validate-phase2.sh`, copied from
`scripts/validate-phase1.sh` per that script's own extension note. Writes a
timestamped record to `validation-results/phase-2/` (plus `latest.json`) -
see `validation-results/README.md` for the record shape.

**Requires:** the phase 2 stack up (`nix run .#up`, now six containers:
`workspace`, `docker-socket-proxy`, `workspace-mcp`, `memory-mcp`,
`chat-mcp`, `orchestrator`), plus everything phase 1's runbook needed
(Docker, curl, python3, a valid `ANTHROPIC_API_KEY`).

## Automated checks (`scripts/validate-phase2.sh`)

1. **Stack up** - all six containers running.
2. **Network segmentation** (fail fast, same philosophy as phase 1 step 2):
   - `memory-mcp` and `docker-socket-proxy` have no internet egress.
   - `orchestrator` **cannot** reach `docker-socket-proxy:2375` directly
     (it's on `internal-docker-proxy`, which orchestrator never joins - see
     `docker-compose.yml`'s network comment). This is the phase-2 analogue
     of phase 1's `step7.cross-container-isolation` finding: don't assume
     the new network split holds, check it.
   - `chat-mcp` and `workspace-mcp` cannot reach `memory-mcp:8803`.
3. **Chat UX** (ADR-0002 Decision 2):
   - `last_seen` in `/api/status` advances between two polls a few seconds
     apart, proving it's a live signal, not a static value.
   - Sending a message and polling `/api/status` observes `status` pass
     through `received` and `working` before landing on `done` (or
     `error`), in that order.
4. **CLI client** (phase-2-scope.md item 3) - `chat_mcp.cli send --wait`
   round-trips a real message against the live `/api/messages`/`/api/send`
   REST surface (the same one the browser UI polls).
5. **Docker-socket-proxy is transparent to the real exec path** (ADR-0002
   Decision 3) - the phase-1-style "ask the LLM to run a real command"
   check, re-run to confirm `workspace-mcp`'s `DOCKER_HOST` pointing at the
   proxy instead of the raw socket didn't break anything.
6. **Memory persistence across a container restart** (ADR-0002 Decision 4)
   - a direct (non-LLM) MCP call creates an entity/observation in
     `memory-mcp`, the container is restarted, and a fresh direct query
     confirms the data survived - proves the named volume is doing the
     persisting, not in-process state.
7. **Memory persistence across sessions** (ADR-0002 Decision 4, the
   property distinct from #6) - drives the *real* chat/LLM path: ask the
   agent to remember a marker value, restart the `orchestrator` container
   (a fresh process = a fresh conversation, since `ChatState`/the LLM's
   context lives only in-process), then ask a new question that requires
   recalling the marker **without it being restated in the prompt**.
8. **MCP tool-surface allowlist** (ADR-0002 Decision 5 prototype) - runs
   `scripts/check-mcp-allowlist.sh` and records its result.

## Manual-only checks (not automated - see rationale)

- **Kata runtime actually took effect** (ADR-0002 Decision 1): on a host
  with Kata installed and `WORKSPACE_RUNTIME=kata` set,
  `docker inspect bulkhead-workspace --format '{{.HostConfig.Runtime}}'` →
  `kata`, not `runc`. Skipped by the automated harness unless
  `WORKSPACE_RUNTIME=kata` is set in the environment it runs in - most
  checkouts won't have Kata installed, and the point of the env-var default
  (see `.env.example`) is that they don't need to.
- **Positive Kata isolation probe**: with Kata active, `workspace_exec`'s
  `uname -r` should differ from the host's `uname -r` - direct evidence of
  a separate guest kernel, not just a relabeled `runc` container. Manual
  because it requires comparing against the *host's* kernel version, which
  the containerized harness has no reliable way to read.
- **Presence flips to stale** (ADR-0002 Decision 2): `docker compose stop
  orchestrator`, wait past `stale_after_seconds` (default 60s, see
  `CHAT_STATUS_STALE_SECONDS`), confirm `/api/status`-derived UI shows
  "not responding", then `docker compose start orchestrator` and confirm it
  recovers. Left manual because deliberately stopping a container in
  someone's running stack isn't something an automated harness should do
  without being asked.

## If something fails

- **Steps 6/7 memory checks fail after a `docker compose restart
  memory-mcp`/`orchestrator`** - give the restarted container a few seconds
  to become ready before querying it; the script retries with a short
  back-off, but a slow host may need longer.
- **Step 5's `DOCKER_HOST` change breaks `workspace_exec` entirely** -
  confirm `docker-socket-proxy` is running and `workspace-mcp`'s `EXEC`,
  `CONTAINERS` and `POST` env vars are all `1` on the proxy (see
  `docker-compose.yml`) - `docker exec` is a two-step API (create the exec
  instance, then start it), both of which are POST requests.
- **Everything else** - see `phase-1-validation.md`'s own troubleshooting
  section; the underlying chat/LLM/workspace_exec path is unchanged by
  phase 2.

## Definition of done

All automated checks pass on a clean `nix run .#up`, recorded under
`validation-results/phase-2/`. The manual-only checks above should be run
at least once by an operator with Kata actually installed before phase 2 is
considered fully closed (as opposed to "closed modulo Kata," which is an
acceptable state if Kata isn't available on the validating machine yet -
see `.env.example`'s `WORKSPACE_RUNTIME` default for why that's a
reversible gap, not a blocker).
