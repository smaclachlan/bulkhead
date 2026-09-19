# Workspace MCP: the sole privileged container. Holds the Docker socket
# (bind-mounted at run time, not baked in here) and exposes exactly one
# tool - see src/workspace_mcp/server.py and
# docs/adr/0001-phase-1-four-container-architecture.md.
#
# Built via `nix run .#build-workspace-mcp-image` (see flake.nix / ADR-0001 §3
# for why this stays a plain Dockerfile instead of a pure Nix derivation).
FROM python:3.12-slim

# Only the docker CLI is needed - this container never runs a docker daemon
# of its own, it shells out to the host daemon via the bind-mounted socket.
# NB: `docker.io` on Debian only ships dockerd/containerd/runc (the daemon);
# the `docker` binary itself lives in the separate `docker-cli` package,
# which is merely a Recommends of docker.io - `--no-install-recommends`
# silently drops it, leaving no `docker` executable at all.
RUN apt-get update \
    && apt-get install -y --no-install-recommends docker-cli \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ ./src/

ENV PYTHONUNBUFFERED=1
ENV PYTHONPATH=/app/src
ENV WORKSPACE_MCP_HOST=0.0.0.0
ENV WORKSPACE_MCP_PORT=8801

EXPOSE 8801

CMD ["python", "-m", "workspace_mcp.server"]
