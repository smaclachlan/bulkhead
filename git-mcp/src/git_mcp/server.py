"""Git MCP: code egress - see README's "Egress" section and
docs/adr/0003-phase-3-git-mcp.md.

Runs two separate MCPServer instances on two ports in one process, sharing
one GitState (same shape Chat MCP already uses for its MCP port + web UI
port - see chat-mcp/src/chat_mcp/server.py):

  - port 8805 ("llm" server): status/diff/log/branch_list/commit/
    create_branch/checkout/push_request - registered in the Orchestrator's
    mcp_agent.config.yaml and attached via server_names, so these are the
    only Git MCP tools the LLM can call.
  - port 8806 ("admin" server): pending_push/push_execute/push_cancel -
    deliberately NEVER registered in mcp_agent.config.yaml/server_names.
    Reached only by orchestrator/src/orchestrator/git_admin_client.py's
    hand-rolled client, called directly by the harness loop after a human
    approves or denies a pending push in chat. This split - not a per-tool
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


@llm_mcp.tool(name="status")
async def status() -> dict:
    """Show the working tree's status (git status --short --branch)."""
    return asdict(await STATE.status())


@llm_mcp.tool(name="diff")
async def diff(path: str = "") -> dict:
    """Show unstaged changes, optionally scoped to one path (empty = whole tree)."""
    return asdict(await STATE.diff(path or None))


@llm_mcp.tool(name="log")
async def log(limit: int = 20) -> dict:
    """Show recent commit history (git log --oneline)."""
    return asdict(await STATE.log(limit))


@llm_mcp.tool(name="branch_list")
async def branch_list() -> dict:
    """List local and remote-tracking branches."""
    return asdict(await STATE.branch_list())


@llm_mcp.tool(name="commit")
async def commit(message: str) -> dict:
    """Stage all changes and commit them locally. Never crosses the network
    boundary - see README's Egress section: local git work isn't gated."""
    return asdict(await STATE.commit(message))


@llm_mcp.tool(name="create_branch")
async def create_branch(name: str) -> dict:
    """Create a new local branch (does not switch to it)."""
    return asdict(await STATE.create_branch(name))


@llm_mcp.tool(name="checkout")
async def checkout(name: str) -> dict:
    """Switch the working tree to an existing local branch."""
    return asdict(await STATE.checkout(name))


@llm_mcp.tool(name="push_request")
async def push_request(branch: str) -> dict:
    """Stage a request to push the current HEAD to `branch` on the
    pre-configured remote. Does NOT push - a human must approve this in chat
    before orchestrator/git_admin_client.py calls push_execute. `branch`
    must match the server-configured GIT_PUSH_BRANCH_PATTERN or this is
    rejected before anything is staged - see ADR-0003 Decision 3/4."""
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
