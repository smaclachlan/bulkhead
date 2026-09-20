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

# /data owned by the non-root user so a *fresh* named volume seeds
# writable (Docker copies the image's ownership at this path into a new
# volume on first use) - but that alone isn't enough for an *existing*
# volume from before this user existed, see docker-entrypoint.sh.
RUN useradd --system --no-create-home --uid 10001 --shell /usr/sbin/nologin app \
    && mkdir -p /data && chown app:app /data
VOLUME ["/data"]

COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 8803

# Stays root (no USER here, unlike every other image in this repo) so the
# entrypoint can fix /data's ownership before dropping to `app` itself -
# see docker-entrypoint.sh for why that's needed on every start, not just
# baked into the image once.
#
# --stateful: default (stateless) mode spawns a new child per request and
# never reaps it (supergateway issue #108) - leaked processes eventually
# stop the container accepting connections. Stays on 3.4.3 rather than
# upgrading since 4.0.0-rc.2 regressed --stateful itself (issue #216).
ENTRYPOINT ["docker-entrypoint.sh"]
