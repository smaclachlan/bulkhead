"""Bearer-token gate for the local chat endpoint.

Not a defense against a network attacker (the port is host-only per
docs/adr/0001-phase-1-four-container-architecture.md §6) - this stops
another local process/user on the same machine from reading the
conversation without the printed URL.
"""

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import PlainTextResponse


class TokenAuthMiddleware(BaseHTTPMiddleware):
    def __init__(self, app, token: str):
        super().__init__(app)
        self._token = token

    async def dispatch(self, request: Request, call_next):
        supplied = request.query_params.get("token") or request.headers.get("x-chat-token")
        if supplied != self._token:
            return PlainTextResponse("forbidden: missing or bad token", status_code=403)
        return await call_next(request)
