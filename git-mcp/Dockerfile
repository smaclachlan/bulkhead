# Git MCP: code egress - see src/git_mcp/server.py and
# docs/adr/0003-phase-3-git-mcp.md. Holds the deploy key (bind-mounted at
# runtime, never baked into the image) and is the only container in the
# topology with network egress to the git remote.
#
# Built via `nix run .#build-git-mcp-image` (see flake.nix / ADR-0001 §3 for
# why this stays a plain Dockerfile instead of a pure Nix derivation, same
# reasoning as workspace-mcp/chat-mcp/orchestrator).
FROM python:3.12-slim

# git for all local/remote operations; openssh-client so `ssh`/`ssh-agent`/
# `ssh-add` (used via GIT_SSH_COMMAND and by git-mcp-unlock, see state.py)
# are present; util-linux for `setsid`, which git-mcp-unlock needs to force
# ssh-add through SSH_ASKPASS instead of prompting on its own tty - normally
# pulled in already as a Debian-essential package, pinned explicitly here so
# that isn't left to chance.
RUN apt-get update \
    && apt-get install -y --no-install-recommends git openssh-client util-linux \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ ./src/

# See git-mcp-unlock's own header comment / state.py's _start_agent for why
# this exists: a passphrase-protected deploy key gets unlocked into this
# container's in-process ssh-agent via `nix run .#git-unlock`, rather than
# forwarding a host ssh-agent socket in (which breaks under Kata/Apple-
# containerization - cross-kernel AF_UNIX sockets don't survive that boundary).
COPY git-mcp-unlock /usr/local/bin/git-mcp-unlock
RUN chmod +x /usr/local/bin/git-mcp-unlock

ENV PYTHONUNBUFFERED=1
ENV PYTHONPATH=/app/src
ENV GIT_MCP_HOST=0.0.0.0
ENV GIT_MCP_LLM_PORT=8805
ENV GIT_MCP_ADMIN_PORT=8806
ENV GIT_REPO_PATH=/repo

EXPOSE 8805 8806

# Identity for local commits made on the agent's behalf - not the human's own
# identity, so commits are attributable to Bulkhead rather than impersonating a
# person. Overridable via env if a deployment wants something else.
ENV GIT_AUTHOR_NAME="Bulkhead Agent"
ENV GIT_AUTHOR_EMAIL="bulkhead-agent@localhost"
ENV GIT_COMMITTER_NAME="Bulkhead Agent"
ENV GIT_COMMITTER_EMAIL="bulkhead-agent@localhost"

CMD ["python", "-m", "git_mcp.server"]
