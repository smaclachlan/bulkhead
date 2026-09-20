"""Workspace MCP: the sole privileged component in the phase 1 topology.

Runs two `MCPServer` instances on two ports in one process, the same split
git-mcp uses (see git-mcp/src/git_mcp/server.py's docstring):

  - LLM port (8801): `exec` only - hardcoded to run a command inside a
    single pre-configured Workspace container via `docker exec`. Unchanged
    since phase 1 - see docs/adr/0001-phase-1-four-container-architecture.md
    and README.md point 4.
  - Admin port (new, docs/adr/0004-git-mcp-bundle-relay.md): `export_bundle`/
    `import_bundle`, moving `git bundle` bytes in and out of the Workspace's
    own git repo. Never registered in mcp_agent.config.yaml/server_names -
    reached only by the Orchestrator's harness-level bundle-relay client,
    the same "whole server stays off the LLM's list" pattern
    docs/adr/0003-phase-3-git-mcp.md Decision 3 uses for git-mcp's admin
    port. This is plumbing between two trusted control-plane containers
    (git-mcp doesn't reach this directly - no network between them, see
    ADR-0004's "why the orchestrator relays, not a new network"); the LLM
    never sees bundle bytes and the Workspace never gains a network route.

No other docker subcommands are reachable from either tool surface, and the
target container is fixed by configuration (WORKSPACE_CONTAINER_ID) - no
caller can select a different container.
"""

import asyncio
import base64
import os
import subprocess

from mcp.server.mcpserver import MCPServer

WORKSPACE_CONTAINER_ID = os.environ["WORKSPACE_CONTAINER_ID"]
EXEC_TIMEOUT_SECONDS = int(os.environ.get("WORKSPACE_EXEC_TIMEOUT_SECONDS", "120"))
BUNDLE_TIMEOUT_SECONDS = int(os.environ.get("WORKSPACE_BUNDLE_TIMEOUT_SECONDS", "120"))
# Both only consumed by _bootstrap_repo_ownership() below.
WORKSPACE_REPO_PATH = os.environ.get("WORKSPACE_REPO_PATH", "/repo")
WORKSPACE_TARGET_USER = os.environ.get("WORKSPACE_TARGET_USER", "10001:10001")

llm_mcp = MCPServer("workspace-mcp", version="0.1.0")
admin_mcp = MCPServer("workspace-mcp-admin", version="0.1.0")


def _decode(output: "str | bytes | None") -> str:
    if output is None:
        return ""
    if isinstance(output, bytes):
        return output.decode("utf-8", errors="replace")
    return output


@llm_mcp.tool(name="exec")
async def exec_command(command: str) -> dict:
    """Run a shell command inside the sandboxed Workspace container.

    The Workspace container is fully network-isolated (README point 4); this
    `docker exec` call is its only inbound path. `command` is run as
    `sh -c "<command>"` inside that one pre-configured container - it cannot
    target any other container or docker subcommand.
    """
    argv = ["docker", "exec", WORKSPACE_CONTAINER_ID, "sh", "-c", command]
    try:
        # Offloaded to a thread so one slow/hung command can't stall the
        # whole server's event loop (confirmed live: it previously did).
        result = await asyncio.to_thread(
            subprocess.run,
            argv,
            capture_output=True,
            text=True,
            timeout=EXEC_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as exc:
        print(f"[workspace-mcp] exec timed out after {EXEC_TIMEOUT_SECONDS}s: {command!r}")
        return {
            "stdout": _decode(exc.stdout),
            "stderr": _decode(exc.stderr)
            + f"\n[workspace-mcp] command timed out after {EXEC_TIMEOUT_SECONDS}s",
            "exit_code": -1,
        }

    # The only audit trail for the only privileged path in the topology -
    # see docs/plans/phase-1-validation.md's containment check.
    print(f"[workspace-mcp] exec exit={result.returncode}: {command!r}")

    return {
        "stdout": result.stdout,
        "stderr": result.stderr,
        "exit_code": result.returncode,
    }


# -- admin-only tools (harness-only, never in server_names) ------------------
#
# Bundle bytes are opaque to the LLM and to this file - git-mcp's gateway
# repo decides what a sync means (which refspec, which direction); these two
# tools just run `git bundle` inside the Workspace and shuttle bytes.
# base64 keeps the transfer JSON/text-safe over MCP rather than needing a
# binary content type.


@admin_mcp.tool(name="export_bundle")
async def export_bundle(refspec: str) -> dict:
    """Run `git bundle create - <refspec>` inside the Workspace and return
    the bundle as base64. `refspec` is passed straight through as `git
    bundle create`'s own selector argument - e.g. `--branches` for every
    local branch, not a fetch-style src:dst mapping (see import_bundle for
    that). `git init`s the Workspace's /repo first if it isn't a repo yet
    (idempotent - a no-op once it is), so this also serves as the very first
    call in the sync relay, before any commit exists. A repo with nothing
    matching `refspec` yet (e.g. no commits) fails with a clear non-zero
    exit_code - the caller should treat that as "nothing to sync", not an
    error."""
    argv = [
        "docker", "exec", WORKSPACE_CONTAINER_ID, "sh", "-c",
        'git init -q >/dev/null 2>&1; git bundle create - "$1"',
        "_", refspec,
    ]
    try:
        result = await asyncio.to_thread(
            subprocess.run,
            argv,
            capture_output=True,
            timeout=BUNDLE_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        return {"data_b64": "", "stderr": "export_bundle timed out", "exit_code": -1}

    print(f"[workspace-mcp] export_bundle {refspec!r} exit={result.returncode}")
    return {
        "data_b64": base64.b64encode(result.stdout).decode("ascii"),
        "stderr": _decode(result.stderr),
        "exit_code": result.returncode,
    }


@admin_mcp.tool(name="import_bundle")
async def import_bundle(data_b64: str, refspec: str) -> dict:
    """Write a bundle (base64) to a temp file inside the Workspace and run
    `git fetch <that file> <refspec>` against /repo, then remove the temp
    file. `git init`s /repo first if needed, same as export_bundle."""
    raw = base64.b64decode(data_b64) if data_b64 else b""
    argv = [
        "docker", "exec", "-i", WORKSPACE_CONTAINER_ID, "sh", "-c",
        'git init -q >/dev/null 2>&1; f=$(mktemp); cat > "$f"; '
        'git fetch --no-tags "$f" "$1"; rc=$?; rm -f "$f"; exit $rc',
        "_", refspec,
    ]
    try:
        result = await asyncio.to_thread(
            subprocess.run,
            argv,
            input=raw,
            capture_output=True,
            timeout=BUNDLE_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        return {"stdout": "", "stderr": "import_bundle timed out", "exit_code": -1}

    print(f"[workspace-mcp] import_bundle {refspec!r} exit={result.returncode}")
    return {
        "stdout": _decode(result.stdout),
        "stderr": _decode(result.stderr),
        "exit_code": result.returncode,
    }


async def _bootstrap_repo_ownership() -> None:
    """Fix WORKSPACE_REPO_PATH's ownership before serving any exec calls.

    A *pre-existing* workspace-repo volume (from before workspace/
    default.nix started baking in a non-root user) keeps its old root
    ownership across an image rebuild - Docker only seeds a volume's
    ownership from the image the first time it's created, never
    retroactively. `-u 0` overrides the exec's user regardless of the
    container's own configured default, so this works either way. Same
    class of bug memory-mcp's docker-entrypoint.sh exists to fix, just done
    from here instead, since `workspace`'s own top-level process is
    deliberately just `sleep infinity` with no startup hook of its own.
    Idempotent (chown of an already-correct tree is a cheap no-op) and
    best-effort - a failure here is logged, not fatal, since it would only
    reproduce as a normal exec failure a caller can already see and act on.
    """
    argv = [
        "docker", "exec", "-u", "0", WORKSPACE_CONTAINER_ID,
        "chown", "-R", WORKSPACE_TARGET_USER, WORKSPACE_REPO_PATH,
    ]
    # A few retries with a short backoff - `workspace` is a `depends_on`,
    # not a health-checked dependency, so it can still be finishing its own
    # startup (image load, `sleep infinity` not running yet) when this
    # process starts.
    attempts = 5
    result = None
    for attempt in range(1, attempts + 1):
        result = await asyncio.to_thread(
            subprocess.run, argv, capture_output=True, text=True, timeout=30,
        )
        if result.returncode == 0:
            print(f"[workspace-mcp] bootstrap: chowned {WORKSPACE_REPO_PATH} to {WORKSPACE_TARGET_USER}")
            return
        if attempt < attempts:
            await asyncio.sleep(2)
    print(
        f"[workspace-mcp] bootstrap: WARNING - could not chown {WORKSPACE_REPO_PATH} "
        f"to {WORKSPACE_TARGET_USER} after {attempts} attempts: {result.stderr.strip()}"
    )


def main() -> None:
    host = os.environ.get("WORKSPACE_MCP_HOST", "0.0.0.0")
    llm_port = int(os.environ.get("WORKSPACE_MCP_PORT", "8801"))
    admin_port = int(os.environ.get("WORKSPACE_MCP_ADMIN_PORT", "8807"))

    async def _run() -> None:
        await _bootstrap_repo_ownership()
        print(f"[workspace-mcp] LLM-facing tools on :{llm_port}, admin tools on :{admin_port}")
        await asyncio.gather(
            llm_mcp.run_streamable_http_async(host=host, port=llm_port),
            admin_mcp.run_streamable_http_async(host=host, port=admin_port),
        )

    asyncio.run(_run())


if __name__ == "__main__":
    main()
