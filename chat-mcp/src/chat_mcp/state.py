"""In-memory conversation state shared between the MCP-facing tools
(Orchestrator side) and the web UI (human side).

Not persisted - phase 1 is a single ephemeral chat session per container
lifetime; see docs/adr/0001-phase-1-four-container-architecture.md.
"""

import asyncio
import itertools
import time
from dataclasses import dataclass
from typing import Literal

Role = Literal["user", "assistant"]


@dataclass
class Message:
    id: int
    role: Role
    text: str
    ts: float


class ChatState:
    def __init__(self) -> None:
        self._messages: list[Message] = []
        self._id_counter = itertools.count(1)
        self._to_orchestrator: "asyncio.Queue[str]" = asyncio.Queue()

    def _append(self, role: Role, text: str) -> Message:
        msg = Message(id=next(self._id_counter), role=role, text=text, ts=time.time())
        self._messages.append(msg)
        return msg

    def add_user_message(self, text: str) -> Message:
        msg = self._append("user", text)
        self._to_orchestrator.put_nowait(text)
        return msg

    def add_assistant_message(self, text: str) -> Message:
        return self._append("assistant", text)

    def messages_since(self, since_id: int) -> list[Message]:
        return [m for m in self._messages if m.id > since_id]

    async def next_user_message(self, timeout_seconds: float) -> "str | None":
        try:
            return await asyncio.wait_for(self._to_orchestrator.get(), timeout=timeout_seconds)
        except asyncio.TimeoutError:
            return None
