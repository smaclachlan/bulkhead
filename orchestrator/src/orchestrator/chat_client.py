"""Direct MCP client to Chat MCP, used by the harness loop in main.py.

The Orchestrator's LLM is deliberately not given chat_send/chat_receive as
callable tools (server_names=["workspace"] only in main.py) - waiting for
human input and relaying the LLM's final reply is harness-level control
flow, not something the LLM should be deciding to invoke mid-reasoning. See
docs/adr/0001-phase-1-four-container-architecture.md and implementation.md's
"Chat loop" description.
"""

import json
from typing import Any

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client


def _result_json(result: Any) -> dict:
    if result.structuredContent is not None:
        return result.structuredContent
    text = result.content[0].text
    return json.loads(text)


class ChatClient:
    def __init__(self, url: str):
        self._url = url
        self._streams_cm = None
        self._session_cm = None
        self._session: "ClientSession | None" = None

    async def __aenter__(self) -> "ChatClient":
        self._streams_cm = streamablehttp_client(self._url)
        read, write, _get_session_id = await self._streams_cm.__aenter__()
        self._session_cm = ClientSession(read, write)
        self._session = await self._session_cm.__aenter__()
        await self._session.initialize()
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb) -> None:
        await self._session_cm.__aexit__(exc_type, exc_val, exc_tb)
        await self._streams_cm.__aexit__(exc_type, exc_val, exc_tb)

    async def receive(self, timeout_seconds: int) -> "str | None":
        """Wait up to timeout_seconds for the next message the human sends."""
        result = await self._session.call_tool(
            "chat_receive", {"timeout_seconds": timeout_seconds}
        )
        return _result_json(result).get("message")

    async def send(self, message: str) -> None:
        """Relay the LLM's reply to the human via the chat UI."""
        await self._session.call_tool("chat_send", {"message": message})
