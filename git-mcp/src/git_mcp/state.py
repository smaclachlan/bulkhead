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
import shutil
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


AGENT_SOCK_PATH = "/tmp/git-mcp-agent.sock"


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
        # docker-compose.yml mounts the deploy key read-only, so its
        # permissions are whatever the host file has - typically too open
        # (group/other readable) for ssh, which refuses to use such a key at
        # all ("UNPROTECTED PRIVATE KEY FILE", confirmed live). A read-only
        # mount can't be chmod'd in place, so copy it to a private,
        # container-local path with 0600 once at startup and use that copy
        # for every ssh invocation instead of the raw mount.
        self._ssh_key_path = self._prepare_ssh_key()
        # A passphrase-protected deploy key can't be unlocked here - there's
        # no TTY and no host-forwarded agent that survives a Kata/Apple-
        # containerization migration (cross-kernel AF_UNIX forwarding doesn't
        # work; see docs/adr/0003 follow-ups on a future git-mcp Kata move).
        # So this container runs its own agent instead: empty at boot (a
        # passphrase-less key still works via the -i fallback in
        # _ssh_env below, unchanged), and an operator can load the real
        # passphrase into it later via `nix run .#git-unlock`, which execs
        # the git-mcp-unlock script over `docker compose exec` (its own pty,
        # independent of this process). Never persisted to disk - a restart
        # drops it, same as this file's existing pending-push-on-restart
        # tradeoff.
        self._start_agent()
        self.push_ttl_seconds = int(os.environ.get("GIT_PUSH_REQUEST_TTL_SECONDS", "900"))
        self._pending: dict[str, PendingPush] = {}
        self._lock = asyncio.Lock()
        # Separate from _lock (which only ever guards _pending) - see
        # _run_git's retry-clone-on-first-real-call below.
        self._init_lock = asyncio.Lock()

    # -- process plumbing -------------------------------------------------

    def _prepare_ssh_key(self) -> str:
        if not os.path.isfile(self.deploy_key_path):
            # Nothing to copy (e.g. the checked-in unconfigured placeholder,
            # or GIT_SSH_DEPLOY_KEY_HOST_PATH just isn't set) - fall through
            # to the original path so ssh fails with a clear "no such
            # identity file" rather than this silently swallowing it.
            return self.deploy_key_path
        private_copy = "/tmp/git-mcp-deploy-key"
        shutil.copyfile(self.deploy_key_path, private_copy)
        os.chmod(private_copy, 0o600)
        return private_copy

    def _start_agent(self) -> None:
        # -D (foreground) instead of ssh-agent's default double-fork-and-
        # detach: that would re-parent the real daemon onto this process (pid
        # 1 in the container), which then has to reap it or leak zombies.
        # Popen without waiting keeps one supervised child instead. If the
        # socket path is already in use (e.g. a prior instance in tests),
        # ssh-agent just exits and _ssh_env's SSH_AUTH_SOCK simply won't
        # resolve to anything - same degrade-to-key-file behavior as no
        # agent at all.
        self._agent_proc = subprocess.Popen(
            ["ssh-agent", "-D", "-a", AGENT_SOCK_PATH],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    def _ssh_env(self) -> dict:
        env = dict(os.environ)
        env["SSH_AUTH_SOCK"] = AGENT_SOCK_PATH
        # IdentitiesOnly=yes: only ever try the one identity named by -i,
        # whether it's served from the agent above or read from disk - never
        # some other identity that might happen to be present. This
        # container's agent is started by _start_agent and only ever loaded
        # with this one deploy key via git-mcp-unlock, so this still holds
        # the guarantee ADR-0003 Decision 4 wants: no credential but the one
        # scoped deploy key can ever authenticate from this container.
        env["GIT_SSH_COMMAND"] = (
            f"ssh -i {self._ssh_key_path} -o IdentitiesOnly=yes "
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
        # The boot-time clone in ensure_repo_initialized can fail purely
        # because a passphrase-protected deploy key's agent was still empty
        # at that point (see git-mcp-unlock/state.py's _start_agent) -
        # unlocking it afterward doesn't itself retry the clone, since
        # nothing was watching for that. So retry lazily here instead: any
        # real git call is a fine trigger, and this is a no-op the moment
        # the repo already exists. Locked so concurrent calls that all see
        # a missing repo don't all try to clone into it at once.
        if not os.path.isdir(os.path.join(self.repo_path, ".git")):
            async with self._init_lock:
                if not os.path.isdir(os.path.join(self.repo_path, ".git")):
                    await self.ensure_repo_initialized()
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
        Decision 1 - this is the "syncing" README point 8 names.

        Deliberately never raises: a bad deploy key, wrong URL, or network
        hiccup here used to crash this whole process before it ever started
        serving either MCP port - which meant the Orchestrator's
        GitAdminClient couldn't even connect and its own startup fell over
        with it (confirmed live: a git-mcp clone failure crash-looped the
        Orchestrator too). Logging and continuing means both MCP servers
        still come up; every git-mcp tool then just returns git's own
        "not a git repository" error until the real problem (e.g. deploy key
        permissions/access) is fixed and git-mcp is restarted to retry."""
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
            print(f"[git-mcp] initial clone failed, continuing unconfigured "
                  f"(git tools will error until this is fixed and git-mcp is "
                  f"restarted): {result.stderr}")
            return

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

    async def diff(self, path: "str | None", rev_range: "str | None" = None) -> PushResult:
        args = ["diff"]
        if rev_range:
            args.append(rev_range)
        if path:
            args += ["--", path]
        return await self._run_git(*args)

    async def log(self, limit: int, path: "str | None" = None, stat: bool = False) -> PushResult:
        args = ["log", f"-n{max(1, limit)}", "--oneline"]
        if stat:
            args.append("--stat")
        if path:
            args += ["--", path]
        return await self._run_git(*args)

    async def branch_list(self, contains: "str | None" = None) -> PushResult:
        args = ["branch", "-a"]
        if contains:
            args += ["--contains", contains]
        return await self._run_git(*args)

    async def show(self, rev: str, path: "str | None") -> PushResult:
        args = ["show", rev]
        if path:
            args += ["--", path]
        return await self._run_git(*args)

    async def remote(self) -> PushResult:
        return await self._run_git("remote", "-v")

    async def rev_parse(self, rev: str) -> PushResult:
        return await self._run_git("rev-parse", rev)

    async def merge_base(self, rev_a: str, rev_b: str) -> PushResult:
        return await self._run_git("merge-base", rev_a, rev_b)

    async def tag_list(self) -> PushResult:
        return await self._run_git("tag", "-l", "--sort=-creatordate")

    async def fetch(self) -> PushResult:
        # Read direction only, and only ever the one pre-configured remote -
        # see server.py's fetch tool docstring and docs/adr/0003 for why this
        # is still within the network-egress boundary push_request/
        # push_execute already opened, not a new one.
        return await self._run_git("fetch", self.remote_name, timeout=120)

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
