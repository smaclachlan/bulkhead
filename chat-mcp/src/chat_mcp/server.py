"""Chat MCP: the human operator's only channel to the Orchestrator.

Runs two things in one process, sharing one in-memory ChatState on one
asyncio event loop:
  - an MCP server (streamable-http) exposing `chat_send`/`chat_receive` for
    the Orchestrator side (see README's Chat Interface MCP section);
  - a small local web UI (Starlette/uvicorn) bound to localhost for the
    human side, gated by a bearer token (see auth.py).

See docs/adr/0001-phase-1-four-container-architecture.md §6.
"""

import asyncio
import os
import secrets

import uvicorn
from mcp.server.mcpserver import MCPServer

from .state import ChatState
from .web import build_web_app

CHAT_STATE = ChatState()

mcp = MCPServer("chat-mcp", version="0.1.0")


@mcp.tool(name="chat_send")
def chat_send(message: str) -> dict:
    """Send a message from the Orchestrator/LLM to the human, shown in the chat UI."""
    msg = CHAT_STATE.add_assistant_message(message)
    return {"ok": True, "id": msg.id}


@mcp.tool(name="chat_receive")
async def chat_receive(timeout_seconds: int = 30) -> dict:
    """Wait up to timeout_seconds for the next message the human sends.

    Returns {"message": null} on timeout - callers should retry rather than
    treat that as an error; there is no other push mechanism in phase 1.
    """
    message = await CHAT_STATE.next_user_message(timeout_seconds)
    return {"message": message}


def _resolve_token() -> str:
    token = os.environ.get("CHAT_MCP_TOKEN")
    if token:
        return token
    token = secrets.token_urlsafe(24)
    print(f"[chat-mcp] generated token (set CHAT_MCP_TOKEN to pin this): {token}")
    return token


async def _run() -> None:
    token = _resolve_token()

    mcp_host = os.environ.get("CHAT_MCP_HOST", "0.0.0.0")
    mcp_port = int(os.environ.get("CHAT_MCP_PORT", "8802"))

    web_host = os.environ.get("CHAT_UI_HOST", "0.0.0.0")
    web_port = int(os.environ.get("CHAT_UI_PORT", "8787"))
    public_host = os.environ.get("CHAT_UI_PUBLIC_HOST", "localhost")

    web_app = build_web_app(CHAT_STATE, token)
    uvicorn_config = uvicorn.Config(web_app, host=web_host, port=web_port, log_level="info")
    web_server = uvicorn.Server(uvicorn_config)

    print(f"[chat-mcp] chat UI: http://{public_host}:{web_port}/?token={token}")

    await asyncio.gather(
        mcp.run_streamable_http_async(host=mcp_host, port=mcp_port),
        web_server.serve(),
    )


def main() -> None:
    asyncio.run(_run())


if __name__ == "__main__":
    main()
