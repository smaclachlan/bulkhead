# Memory MCP: the reference knowledge-graph memory server
# (entities/relations/observations, modelcontextprotocol/servers/src/memory),
# bridged from its native stdio transport to streamable-http via
# supergateway so it exposes an HTTP /mcp endpoint like workspace-mcp and
# chat-mcp do, instead of needing to be spawned as a subprocess by the
# Orchestrator itself. See docs/adr/0002-phase-2-isolation-ux-memory.md
# Decision 4.
#
# Bulkhead's first Node-based container - Dockerfile + package.json is the
# same per-image pattern ADR-0001 §3 uses for the three Python containers,
# just a different runtime; see that ADR for why these stay plain
# Dockerfiles instead of pure Nix derivations.
#
# Built via `nix run .#build-memory-mcp-image` (see flake.nix).
FROM node:20-slim

WORKDIR /app

COPY package.json .
RUN npm install --omit=dev

# The knowledge graph's JSON store. Unlike chat-mcp's ChatState (deliberately
# ephemeral, see state.py), this is meant to survive a container recreate -
# docker-compose.yml mounts a named volume here.
ENV MEMORY_FILE_PATH=/data/memory.jsonl
ENV MEMORY_MCP_PORT=8803
VOLUME ["/data"]

EXPOSE 8803

CMD ["sh", "-c", "node_modules/.bin/supergateway --stdio 'node_modules/.bin/mcp-server-memory' --outputTransport streamableHttp --port ${MEMORY_MCP_PORT}"]
