# Workspace MCP: the sole privileged container, exposing exactly one tool -
# see src/workspace_mcp/server.py and
# docs/adr/0001-phase-1-four-container-architecture.md. As of phase 2
# (docs/adr/0002-phase-2-isolation-ux-memory.md §3), the raw Docker socket
# is no longer bind-mounted here directly - `docker-socket-proxy` holds it
# instead, and this container's `docker` CLI talks to that scoped proxy
# over the network via DOCKER_HOST (see docker-compose.yml).
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

# Runs as non-root: this container talks to docker-socket-proxy over the
# network (DOCKER_HOST=tcp://..., see docker-compose.yml) rather than
# holding the Docker socket itself - ADR-0002 §3 moved that bind mount
# to docker-socket-proxy - so it needs no host-level privilege to do its
# job, just the docker-cli binary and network reachability.
RUN useradd --system --no-create-home --uid 10001 --shell /usr/sbin/nologin app
USER app

CMD ["python", "-m", "workspace_mcp.server"]
