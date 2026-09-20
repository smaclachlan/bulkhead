"""Direct MCP client to Workspace MCP's admin port (export_bundle/
import_bundle), used by the harness loop in main.py to relay `git bundle`
bytes to/from Git MCP's gateway repo.

These two tools are deliberately not registered in mcp_agent.config.yaml or
server_names - the LLM never sees bundle bytes or the two containers'
relationship, same reasoning chat_client.py/git_admin_client.py give for
keeping their own harness-only tools off the LLM's list. See
docs/adr/0004-git-mcp-bundle-relay.md.
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


class WorkspaceAdminClient:
    def __init__(self, url: str):
        self._url = url
        self._streams_cm = None
        self._session_cm = None
        self._session: "ClientSession | None" = None

    async def __aenter__(self) -> "WorkspaceAdminClient":
        self._streams_cm = streamablehttp_client(self._url)
        read, write, _get_session_id = await self._streams_cm.__aenter__()
        self._session_cm = ClientSession(read, write)
        self._session = await self._session_cm.__aenter__()
        await self._session.initialize()
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb) -> None:
        await self._session_cm.__aexit__(exc_type, exc_val, exc_tb)
        await self._streams_cm.__aexit__(exc_type, exc_val, exc_tb)

    async def export_bundle(self, refspec: str) -> dict:
        """Bundle refs matching `refspec` out of the Workspace's /repo."""
        result = await self._session.call_tool("export_bundle", {"refspec": refspec})
        return _result_json(result)

    async def import_bundle(self, data_b64: str, refspec: str) -> dict:
        """Absorb a base64 bundle into the Workspace's /repo per `refspec`."""
        result = await self._session.call_tool(
            "import_bundle", {"data_b64": data_b64, "refspec": refspec}
        )
        return _result_json(result)
