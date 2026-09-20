"""Git MCP: code egress - see README's "Egress" section,
docs/adr/0003-phase-3-git-mcp.md, and docs/adr/0004-git-mcp-bundle-relay.md
(the bare-mirror-gateway rework this file now reflects).

Runs two separate MCPServer instances on two ports in one process, sharing
one GitState (same shape Chat MCP already uses for its MCP port + web UI
port - see chat-mcp/src/chat_mcp/server.py):

  - port 8805 ("llm" server): fetch/push_request only - registered in the
    Orchestrator's mcp_agent.config.yaml and attached via server_names, so
    these are the only Git MCP tools the LLM can call. Everything that used
    to live here (status/diff/log/commit/checkout/etc., ADR-0003 Decision 2)
    moved to the Workspace, which now has git installed - see
    docs/adr/0004-git-mcp-bundle-relay.md for why.
  - port 8806 ("admin" server): pending_push/push_execute/push_cancel plus
    the two bundle-relay tools (import_bundle/export_bundle) - deliberately
    NEVER registered in mcp_agent.config.yaml/server_names. Reached only by
    orchestrator/src/orchestrator/git_admin_client.py's hand-rolled client,
    called directly by the harness loop: push_execute after a human approves
    a pending push, and the bundle tools on every turn to keep the gateway
    and the Workspace's local branches in sync. This split - not a per-tool
    filter, which mcp-agent doesn't have - is what keeps push_execute
    structurally unreachable by the LLM. See ADR-0003 Decision 3.
"""

import asyncio
import os
from dataclasses import asdict

from mcp.server.mcpserver import MCPServer

from .state import GitError, GitState

STATE = GitState()

llm_mcp = MCPServer("git-mcp", version="0.1.0")
admin_mcp = MCPServer("git-mcp-admin", version="0.1.0")


# -- LLM-facing tools (ungated per README's Egress section) -----------------


@llm_mcp.tool(name="fetch")
async def fetch() -> dict:
    """Refresh the gateway's view of every branch/tag from the pre-configured
    remote. Read-only against the remote - fetches, never pushes, and only
    ever the one already-configured remote, never an arbitrary URL. Call
    this before relying on the remote's current state; the harness syncs
    whatever this brings down back into the Workspace after your turn."""
    return asdict(await STATE.fetch())


@llm_mcp.tool(name="push_request")
async def push_request(branch: str) -> dict:
    """Stage a request to push your Workspace-local branch `branch` to the
    same-named branch on the pre-configured remote. Does NOT push - a human
    must approve this in chat before the harness calls push_execute.
    `branch` must match the server-configured GIT_PUSH_BRANCH_PATTERN or
    this is rejected before anything is staged - see ADR-0003 Decision 3/4.
    The harness syncs your latest commits into the gateway immediately
    before staging and again immediately before executing, so there's no
    need to call anything else first."""
    try:
        pending = await STATE.push_request(branch)
    except GitError as exc:
        return {"ok": False, "error": str(exc)}
    return {"ok": True, **asdict(pending)}


# -- harness-only admin tools (never in server_names) ------------------------


@admin_mcp.tool(name="pending_push")
async def pending_push() -> dict:
    """List push requests awaiting human approval. Harness-only - called by
    the Orchestrator's loop, never the LLM."""
    return {"pending": [asdict(p) for p in await STATE.list_pending()]}


@admin_mcp.tool(name="push_execute")
async def push_execute(request_id: str) -> dict:
    """Execute a push the human has approved. Harness-only - the LLM cannot
    reach this tool (see server.py's module docstring). Only succeeds for a
    request_id that is currently pending and unexpired."""
    return asdict(await STATE.execute(request_id))


@admin_mcp.tool(name="push_cancel")
async def push_cancel(request_id: str) -> dict:
    """Cancel a pending push (human denied it). Harness-only."""
    return {"ok": await STATE.cancel(request_id)}


@admin_mcp.tool(name="export_bundle")
async def export_bundle(refspec: str) -> dict:
    """Bundle refs matching `refspec` (a ref pattern, e.g. `refs/heads/*`)
    out of the gateway repo, base64-encoded. Harness-only - see
    docs/adr/0004-git-mcp-bundle-relay.md."""
    return await STATE.export_bundle(refspec)


@admin_mcp.tool(name="import_bundle")
async def import_bundle(data_b64: str, refspec: str) -> dict:
    """Absorb a base64 bundle into the gateway repo's refs per `refspec` (a
    src:dst fetch refspec, e.g. `+refs/heads/*:refs/heads/*`). Harness-only -
    see docs/adr/0004-git-mcp-bundle-relay.md."""
    return asdict(await STATE.import_bundle(data_b64, refspec))


async def _run() -> None:
    await STATE.ensure_repo_initialized()

    host = os.environ.get("GIT_MCP_HOST", "0.0.0.0")
    llm_port = int(os.environ.get("GIT_MCP_LLM_PORT", "8805"))
    admin_port = int(os.environ.get("GIT_MCP_ADMIN_PORT", "8806"))

    print(f"[git-mcp] LLM-facing tools on :{llm_port}, admin tools on :{admin_port}")
    await asyncio.gather(
        llm_mcp.run_streamable_http_async(host=host, port=llm_port),
        admin_mcp.run_streamable_http_async(host=host, port=admin_port),
    )


def main() -> None:
    asyncio.run(_run())


if __name__ == "__main__":
    main()
