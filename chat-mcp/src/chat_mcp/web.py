"""The human-facing side of Chat MCP: a small local web UI and the HTTP API
it polls. Kept separate from the MCP-facing tools in server.py so the two
sides of the conversation stay independently testable.
"""

from pathlib import Path

from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import FileResponse, JSONResponse
from starlette.routing import Route

from .auth import TokenAuthMiddleware
from .state import ChatState

STATIC_DIR = Path(__file__).parent / "static"


def build_web_app(state: ChatState, token: str) -> Starlette:
    async def index(request: Request):
        return FileResponse(STATIC_DIR / "index.html")

    async def get_messages(request: Request):
        since = int(request.query_params.get("since", "0"))
        messages = state.messages_since(since)
        return JSONResponse(
            {
                "messages": [
                    {"id": m.id, "role": m.role, "text": m.text, "ts": m.ts}
                    for m in messages
                ]
            }
        )

    async def post_send(request: Request):
        body = await request.json()
        text = (body.get("text") or "").strip()
        if not text:
            return JSONResponse({"error": "empty message"}, status_code=400)
        msg = state.add_user_message(text)
        return JSONResponse({"id": msg.id})

    app = Starlette(
        routes=[
            Route("/", index, methods=["GET"]),
            Route("/api/messages", get_messages, methods=["GET"]),
            Route("/api/send", post_send, methods=["POST"]),
        ],
    )
    app.add_middleware(TokenAuthMiddleware, token=token)
    return app
