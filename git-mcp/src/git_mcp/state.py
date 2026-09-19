"""Shared git state for both of Git MCP's ports - see server.py's docstring
and docs/adr/0003-phase-3-git-mcp.md Decision 3 for why this is split across
two `MCPServer` instances in one process rather than one server with a mixed
tool list.
"""

from __future__ import annotations

import asyncio
import fnmatch
import os
import secrets
import subprocess
import time
from dataclasses import dataclass


def _decode(output: "str | bytes | None") -> str:
    if output is None:
        return ""
    if isinstance(output, bytes):
        return output.decode("utf-8", errors="replace")
    return output


@dataclass
class PendingPush:
    request_id: str
    branch: str
    remote: str
    created_at: float


@dataclass
class PushResult:
    stdout: str
    stderr: str
    exit_code: int


class GitError(Exception):
    """A push_request that fails validation before anything is staged."""


class GitState:
    def __init__(self) -> None:
        self.repo_path = os.environ.get("GIT_REPO_PATH", "/repo")
        self.remote_name = os.environ.get("GIT_REMOTE_NAME", "origin")
        self.remote_url = os.environ.get("GIT_REMOTE_URL", "")
        # Unconfigured checkouts must still come up (same pattern as
        # WORKSPACE_RUNTIME defaulting to runc, CHAT_MCP_TOKEN
        # auto-generating) - git-mcp starts and serves its tools either way,
        # they just all report "not configured" until GIT_REMOTE_URL is set.
        self.configured = bool(self.remote_url)
        self.branch_pattern = os.environ.get("GIT_PUSH_BRANCH_PATTERN", "agent/*")
        self.deploy_key_path = os.environ.get(
            "GIT_SSH_DEPLOY_KEY_PATH", "/run/secrets/deploy_key"
        )
        self.push_ttl_seconds = int(os.environ.get("GIT_PUSH_REQUEST_TTL_SECONDS", "900"))
        self._pending: dict[str, PendingPush] = {}
        self._lock = asyncio.Lock()

    # -- process plumbing -------------------------------------------------

    def _ssh_env(self) -> dict:
        env = dict(os.environ)
        # IdentitiesOnly=yes: only try this one key, never fall back to an
        # ssh-agent key or another identity that might happen to be present
        # in the container - the deploy key is the only credential this
        # container is meant to authenticate with (ADR-0003 Decision 4).
        env["GIT_SSH_COMMAND"] = (
            f"ssh -i {self.deploy_key_path} -o IdentitiesOnly=yes "
            "-o StrictHostKeyChecking=accept-new"
        )
        return env

    async def _run_git(self, *args: str, timeout: int = 60) -> PushResult:
        if not self.configured:
            return PushResult(
                stdout="",
                stderr="git-mcp is not configured - set GIT_REMOTE_URL in .env "
                "(see README's Git MCP setup section)",
                exit_code=-1,
            )
        argv = ["git", "-C", self.repo_path, *args]
        result = await asyncio.to_thread(
            subprocess.run,
            argv,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=self._ssh_env(),
        )
        return PushResult(
            stdout=_decode(result.stdout),
            stderr=_decode(result.stderr),
            exit_code=result.returncode,
        )

    # -- init ---------------------------------------------------------------

    async def ensure_repo_initialized(self) -> None:
        """Clone GIT_REMOTE_URL into the shared volume on first start; skip if
        a prior session's volume already has a checkout. See ADR-0003
        Decision 1 - this is the "syncing" README point 8 names."""
        if not self.configured:
            print("[git-mcp] GIT_REMOTE_URL not set - starting unconfigured, "
                  "tools will report this until it's set (see README's Git MCP setup)")
            return

        git_dir = os.path.join(self.repo_path, ".git")
        if os.path.isdir(git_dir):
            print(f"[git-mcp] {self.repo_path} already a git checkout, skipping clone")
            return

        os.makedirs(self.repo_path, exist_ok=True)
        print(f"[git-mcp] cloning {self.remote_url} into {self.repo_path}")
        result = await asyncio.to_thread(
            subprocess.run,
            ["git", "clone", self.remote_url, self.repo_path],
            capture_output=True,
            text=True,
            timeout=300,
            env=self._ssh_env(),
        )
        if result.returncode != 0:
            raise RuntimeError(f"initial clone failed: {result.stderr}")

        # No arbitrary hooks running inside this container on checkout/push -
        # ADR-0003 Decision 4 ("no hooks"). Point hooksPath somewhere that
        # never contains anything, rather than trusting whatever the clone
        # brought down in .git/hooks.
        os.makedirs("/etc/git-mcp/empty-hooks", exist_ok=True)
        await self._run_git("config", "core.hooksPath", "/etc/git-mcp/empty-hooks")
        print("[git-mcp] clone complete, hooks disabled")

    # -- read-only / local-write tools (LLM-facing) --------------------------

    async def status(self) -> PushResult:
        return await self._run_git("status", "--short", "--branch")

    async def diff(self, path: "str | None") -> PushResult:
        args = ["diff"]
        if path:
            args += ["--", path]
        return await self._run_git(*args)

    async def log(self, limit: int) -> PushResult:
        return await self._run_git("log", f"-n{max(1, limit)}", "--oneline")

    async def branch_list(self) -> PushResult:
        return await self._run_git("branch", "-a")

    async def commit(self, message: str) -> PushResult:
        add_result = await self._run_git("add", "-A")
        if add_result.exit_code != 0:
            return add_result
        return await self._run_git("commit", "-m", message)

    async def create_branch(self, name: str) -> PushResult:
        return await self._run_git("branch", name)

    async def checkout(self, name: str) -> PushResult:
        return await self._run_git("checkout", name)

    # -- the one gated action -----------------------------------------------

    async def push_request(self, branch: str) -> PendingPush:
        """Stage a pending push. Validates the branch server-side against
        GIT_PUSH_BRANCH_PATTERN - never trusts the caller's judgment about
        what's an allowed branch (ADR-0003 Decision 3/4). Does not push."""
        if not self.configured:
            raise GitError(
                "git-mcp is not configured - set GIT_REMOTE_URL in .env "
                "(see README's Git MCP setup section)"
            )
        if not fnmatch.fnmatch(branch, self.branch_pattern):
            raise GitError(
                f"branch {branch!r} does not match the allowed pattern "
                f"{self.branch_pattern!r} - push rejected before staging anything"
            )
        request_id = secrets.token_hex(8)
        pending = PendingPush(
            request_id=request_id,
            branch=branch,
            remote=self.remote_name,
            created_at=time.time(),
        )
        async with self._lock:
            self._pending[request_id] = pending
        print(f"[git-mcp] push_request staged: {pending} (awaiting human approval)")
        return pending

    # -- admin tools (harness-only, never given to the LLM) ------------------

    async def list_pending(self) -> list[PendingPush]:
        async with self._lock:
            self._expire_locked()
            return list(self._pending.values())

    async def cancel(self, request_id: str) -> bool:
        async with self._lock:
            return self._pending.pop(request_id, None) is not None

    async def execute(self, request_id: str) -> PushResult:
        async with self._lock:
            self._expire_locked()
            pending = self._pending.pop(request_id, None)
        if pending is None:
            return PushResult(
                stdout="",
                stderr=f"no pending push request {request_id!r} (unknown, expired, or already executed)",
                exit_code=-1,
            )
        print(f"[git-mcp] executing approved push: {pending}")
        return await self._run_git(
            "push", pending.remote, f"HEAD:{pending.branch}", timeout=120
        )

    def _expire_locked(self) -> None:
        now = time.time()
        expired = [
            rid
            for rid, p in self._pending.items()
            if now - p.created_at > self.push_ttl_seconds
        ]
        for rid in expired:
            print(f"[git-mcp] pending push {rid} expired without approval")
            del self._pending[rid]
