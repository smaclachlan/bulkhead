# Chat MCP: the human operator's only channel to the Orchestrator - local
# web UI plus the MCP server the Orchestrator talks to. See
# src/chat_mcp/server.py and docs/adr/0001-phase-1-four-container-architecture.md §6.
#
# Built via `nix run .#build-chat-mcp-image` (see flake.nix / ADR-0001 §3 for
# why this stays a plain Dockerfile instead of a pure Nix derivation).
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ ./src/

ENV PYTHONUNBUFFERED=1
ENV PYTHONPATH=/app/src
ENV CHAT_MCP_HOST=0.0.0.0
ENV CHAT_MCP_PORT=8802
ENV CHAT_UI_HOST=0.0.0.0
ENV CHAT_UI_PORT=8787

EXPOSE 8802 8787

CMD ["python", "-m", "chat_mcp.server"]
