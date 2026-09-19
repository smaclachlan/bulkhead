"""Workspace MCP: the sole privileged component in the phase 1 topology.

Exposes exactly one tool, `exec`, hardcoded to run a command inside a single
pre-configured Workspace container via `docker exec`. This is deliberately
the only way into the Workspace container - see
docs/adr/0001-phase-1-four-container-architecture.md and README.md point 4.

No other docker subcommands are reachable from this tool surface, and the
target container is fixed by configuration (WORKSPACE_CONTAINER_ID) - the
caller cannot select a different container.
"""

import os
import subprocess

from mcp.server.mcpserver import MCPServer

WORKSPACE_CONTAINER_ID = os.environ["WORKSPACE_CONTAINER_ID"]
EXEC_TIMEOUT_SECONDS = int(os.environ.get("WORKSPACE_EXEC_TIMEOUT_SECONDS", "120"))

mcp = MCPServer("workspace-mcp", version="0.1.0")


def _decode(output: "str | bytes | None") -> str:
    if output is None:
        return ""
    if isinstance(output, bytes):
        return output.decode("utf-8", errors="replace")
    return output


@mcp.tool(name="exec")
def exec_command(command: str) -> dict:
    """Run a shell command inside the sandboxed Workspace container.

    The Workspace container is fully network-isolated (README point 4); this
    `docker exec` call is its only inbound path. `command` is run as
    `sh -c "<command>"` inside that one pre-configured container - it cannot
    target any other container or docker subcommand.
    """
    argv = ["docker", "exec", WORKSPACE_CONTAINER_ID, "sh", "-c", command]
    try:
        result = subprocess.run(
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


def main() -> None:
    host = os.environ.get("WORKSPACE_MCP_HOST", "0.0.0.0")
    port = int(os.environ.get("WORKSPACE_MCP_PORT", "8801"))
    mcp.run(transport="streamable-http", host=host, port=port)


if __name__ == "__main__":
    main()
