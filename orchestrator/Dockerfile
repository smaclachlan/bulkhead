# Orchestrator: the LLM-facing harness. No shell tool is ever registered -
# this image intentionally has no build toolchain beyond what pip itself
# needs, and the runtime has no bash-shaped tool wired into mcp-agent. See
# src/orchestrator/main.py and docs/adr/0001-phase-1-four-container-architecture.md §2.
#
# Built via `nix run .#build-orchestrator-image` (see flake.nix / ADR-0001 §3
# for why this stays a plain Dockerfile instead of a pure Nix derivation).
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ ./src/
COPY mcp_agent.config.yaml .

ENV PYTHONUNBUFFERED=1
ENV PYTHONPATH=/app/src
ENV CHAT_MCP_URL=http://chat-mcp:8802/mcp

# mcp_agent.secrets.yaml is NOT baked in - supply ANTHROPIC_API_KEY at
# runtime (Compose env/secret) instead, so credentials never live in the
# image. See mcp_agent.secrets.yaml.example.

# Runs as non-root - no volumes, no shell tool wired in (see header comment
# above), nothing here needs host-level access.
RUN useradd --system --no-create-home --uid 10001 --shell /usr/sbin/nologin app
USER app

CMD ["python", "-m", "orchestrator.main"]
