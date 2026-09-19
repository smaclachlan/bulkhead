"""Direct MCP client to Git MCP's admin port (pending_push/push_execute/
push_cancel), used by the harness loop in main.py.

These three tools are deliberately not registered in mcp_agent.config.yaml
or server_names - the LLM cannot reach them at all. Approving or denying a
pending push is harness-level control flow triggered by an exact human chat
command, the same reasoning chat_client.py gives for keeping chat_send/
chat_receive off the LLM's tool list. See
docs/adr/0003-phase-3-git-mcp.md Decision 3.
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


class GitAdminClient:
    def __init__(self, url: str):
        self._url = url
        self._streams_cm = None
        self._session_cm = None
        self._session: "ClientSession | None" = None

    async def __aenter__(self) -> "GitAdminClient":
        self._streams_cm = streamablehttp_client(self._url)
        read, write, _get_session_id = await self._streams_cm.__aenter__()
        self._session_cm = ClientSession(read, write)
        self._session = await self._session_cm.__aenter__()
        await self._session.initialize()
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb) -> None:
        await self._session_cm.__aexit__(exc_type, exc_val, exc_tb)
        await self._streams_cm.__aexit__(exc_type, exc_val, exc_tb)

    async def pending(self) -> list[dict]:
        result = await self._session.call_tool("pending_push", {})
        return _result_json(result).get("pending", [])

    async def execute(self, request_id: str) -> dict:
        result = await self._session.call_tool("push_execute", {"request_id": request_id})
        return _result_json(result)

    async def cancel(self, request_id: str) -> bool:
        result = await self._session.call_tool("push_cancel", {"request_id": request_id})
        return _result_json(result).get("ok", False)
