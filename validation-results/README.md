# Validation results

Attestation trail produced by `scripts/validate-<phase>.sh`
(`validate-phase1.sh`, `validate-phase2.sh`, `validate-phase3.sh`). Each run
appends a timestamped JSON record under `<phase>/`, plus overwrites
`<phase>/latest.json` for convenience.

These are committed to git deliberately - the point is a durable, append-only
record of when the containment properties in
`docs/adr/0001-phase-1-four-container-architecture.md` were actually checked
and what the result was, not just a pass/fail shown once in a terminal.
That includes checks that speak MCP directly to `workspace-mcp`'s endpoint
(bypassing the chat/LLM path) to probe tool listing, tool schema, real
exec/filesystem access, and cross-container reachability - a check failing
here (e.g. `step7.cross-container-isolation`) is meant to surface a real gap
against the ADR's stated intent, not be explained away.

## Record shape

```json
{
  "phase": "phase-1",
  "timestamp_utc": "2026-09-19T14-00-00Z",
  "git_commit": "<sha of HEAD at run time>",
  "git_dirty": false,
  "project": "bulkhead",
  "checks": [
    {"id": "step2.workspace-no-network", "status": "pass", "description": "...", "detail": "..."}
  ],
  "summary": {"pass": 9, "fail": 0, "total": 9}
}
```

`scripts/validate-phase2.sh` adds a third check status, `"skip"`, for checks
that are legitimately conditional on host setup rather than pass/fail (e.g.
the Kata runtime check, only meaningful when `WORKSPACE_RUNTIME=kata` is
set - see `docs/plans/phase-2-validation.md`). A skip is recorded in
`checks`/`summary.skip` but doesn't count toward `pass`/`fail`, and doesn't
affect the script's exit code.

`validate-phase2.sh`/`validate-phase3.sh` also take an optional profile
env-file argument (e.g. `sh scripts/validate-phase2.sh ./rust-build.conf`),
same convention as `nix run .#up`/`down`/`git-unlock` - see README's
"Workspace image and concurrent profiles". The `"project"` field records
which profile a run targeted (`"bulkhead"` for the default one). The
default profile's own paths and filenames are unchanged by this - a
non-default profile's results are kept out of its way, nested one level
deeper at `<phase>/profiles/<project-name>/` (its own timestamped files
plus its own `latest.json`), so two concurrently-validated profiles never
stomp each other's records. Records written before this field existed
simply lack `"project"` - that's expected, not a schema violation.

## Adding a new phase

Copy the latest `scripts/validate-phaseN.sh` as a starting point, change its
`PHASE` variable, and add `check_step*` logic for that phase's own runbook.
The `record`/JSON-writing plumbing at the bottom is already phase-agnostic.
