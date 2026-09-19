"""In-memory conversation state shared between the MCP-facing tools
(Orchestrator side) and the web UI (human side).

Not persisted - phase 1 is a single ephemeral chat session per container
lifetime; see docs/adr/0001-phase-1-four-container-architecture.md.

Phase 2 (docs/adr/0002-phase-2-isolation-ux-memory.md Decision 2) adds two
UX-feedback fields, both plain state - no new freeform-text tool surface:
`last_seen` (presence) and `status` (activity), each with its own timestamp
so the UI can tell "stale" from "no activity yet reported".
"""

import asyncio
import itertools
import time
from dataclasses import dataclass
from typing import Literal

Role = Literal["user", "assistant"]
Status = Literal["idle", "received", "working", "done", "error"]


@dataclass
class Message:
    id: int
    role: Role
    text: str
    ts: float


class ChatState:
    def __init__(self, stale_after_seconds: int = 60) -> None:
        self._messages: list[Message] = []
        self._id_counter = itertools.count(1)
        self._to_orchestrator: "asyncio.Queue[str]" = asyncio.Queue()
        self.stale_after_seconds = stale_after_seconds
        self.last_seen: "float | None" = None
        self.status: Status = "idle"
        self.status_ts: "float | None" = None

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

    def mark_seen(self) -> None:
        """Called on every `chat_receive` invocation, whether or not it
        returns a message - this is the only signal Chat MCP has that the
        Orchestrator's poll loop is alive at all (see server.py)."""
        self.last_seen = time.time()

    def set_status(self, status: Status) -> None:
        self.status = status
        self.status_ts = time.time()
