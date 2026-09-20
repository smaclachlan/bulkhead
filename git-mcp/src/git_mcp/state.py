"""Shared git state for both of Git MCP's ports - see server.py's docstring
and docs/adr/0004-git-mcp-bundle-relay.md for why this holds a *bare mirror*
gateway repo rather than the shared working tree ADR-0003 originally used.

Git-mcp no longer runs any git operation that can execute attacker-reachable
code: no working tree (no checkout, so no smudge/clean/textconv filters), no
LLM-facing local-ops tools (no commit/checkout - those moved to the
Workspace, where hooks are contained rather than sitting next to the deploy
key), and every invocation here forces the dangerous config knobs off
regardless of what's on disk (HARDENED_GIT_ARGS below) - defense in depth in
case the bare-repo assumption above is ever wrong, not the primary control.
"""

from __future__ import annotations

import asyncio
import base64
import fnmatch
import os
import secrets
import shutil
import subprocess
import tempfile
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

# Forced on every git invocation against the gateway repo, at higher
# precedence than any on-disk config (`-c` beats a config file) - hooks,
# fsmonitor, the pager, and credential/askpass helpers are all ways git turns
# config into an executed command. The gateway repo is bare (no work tree),
# which already removes the checkout-triggered ones (smudge/clean/textconv
# need a work tree); these cover the rest, in case that assumption is ever
# violated by a future change. See docs/adr/0004-git-mcp-bundle-relay.md.
HARDENED_GIT_ARGS = [
    "-c", "core.hooksPath=/dev/null",
    "-c", "core.fsmonitor=",
    "-c", "core.pager=cat",
    "-c", "core.askPass=",
    "-c", "credential.helper=",
]


class GitState:
    def __init__(self) -> None:
        # The gateway is a private, git-mcp-only bare mirror of the remote -
        # not the Workspace's working tree, which git-mcp no longer touches
        # at all (ADR-0004). "Mirror" (git clone --mirror) rather than a
        # plain bare clone: a plain `git fetch` on it then refreshes every
        # ref (branches, tags) to exactly match origin, which is what
        # `fetch()`/push staging below assume.
        self.gateway_path = os.environ.get("GIT_GATEWAY_PATH", "/gitdir")
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
        # _run_gateway_git's retry-clone-on-first-real-call below.
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
        # Isolate every invocation from any system/global gitconfig the
        # image or a volume might carry - only the gateway repo's own config
        # (itself overridden by HARDENED_GIT_ARGS above) is ever consulted.
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_TERMINAL_PROMPT"] = "0"
        return env

    def _gateway_argv(self, *args: str) -> list[str]:
        return ["git", "--git-dir", self.gateway_path, *HARDENED_GIT_ARGS, *args]

    async def _run_gateway_git(self, *args: str, timeout: int = 60) -> PushResult:
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
        # the gateway already exists. Locked so concurrent calls that all
        # see a missing gateway don't all try to clone into it at once.
        if not os.path.isfile(os.path.join(self.gateway_path, "HEAD")):
            async with self._init_lock:
                if not os.path.isfile(os.path.join(self.gateway_path, "HEAD")):
                    await self.ensure_repo_initialized()
        result = await asyncio.to_thread(
            subprocess.run,
            self._gateway_argv(*args),
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
        """Mirror-clone GIT_REMOTE_URL into the private gateway path on
        first start; skip if a prior session's volume already has one. See
        docs/adr/0004-git-mcp-bundle-relay.md - this replaces ADR-0003's
        "clone into the shared volume" (there is no shared volume any more).

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

        if os.path.isfile(os.path.join(self.gateway_path, "HEAD")):
            print(f"[git-mcp] {self.gateway_path} already a gateway mirror, skipping clone")
            return

        os.makedirs(self.gateway_path, exist_ok=True)
        print(f"[git-mcp] mirror-cloning {self.remote_url} into {self.gateway_path}")
        result = await asyncio.to_thread(
            subprocess.run,
            ["git", "clone", "--mirror", self.remote_url, self.gateway_path],
            capture_output=True,
            text=True,
            timeout=300,
            env=self._ssh_env(),
        )
        if result.returncode != 0:
            print(f"[git-mcp] initial mirror clone failed, continuing unconfigured "
                  f"(git tools will error until this is fixed and git-mcp is "
                  f"restarted): {result.stderr}")
            return

        # Persisted for defense-in-depth/clarity, even though HARDENED_GIT_ARGS
        # above already forces this on every invocation regardless of what's
        # on disk - see this module's docstring.
        await self._run_gateway_git("config", "core.hooksPath", "/dev/null")
        print("[git-mcp] mirror clone complete")

    # -- LLM-facing tools -----------------------------------------------------
    #
    # Deliberately just two: everything that doesn't cross the network stays
    # in the Workspace now (git is installed there - see workspace/default.nix
    # and docs/adr/0004-git-mcp-bundle-relay.md), so git-mcp's own tool
    # surface is close to a pure auth proxy: pull from the remote, and stage
    # a gated push to it. No status/diff/log/commit/checkout/etc live here
    # any more - there is nothing left for a malicious commit or config value
    # to run against.

    async def fetch(self) -> PushResult:
        """Refresh every ref (branches, tags) in the gateway mirror from the
        pre-configured remote. Read direction only - the one other tool here
        besides push_execute that reaches the network, and still within the
        same boundary push_execute already opened (docs/adr/0003)."""
        return await self._run_gateway_git("fetch", self.remote_name, timeout=120)

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

    # -- bundle relay (harness-only, never given to the LLM) ------------------
    #
    # The Orchestrator's harness (never the LLM) shuttles `git bundle` bytes
    # between here and workspace-mcp's matching admin tools - see
    # docs/adr/0004-git-mcp-bundle-relay.md for why the relay goes through
    # the Orchestrator rather than a new network directly between the two.
    # Bundles are inert data: importing one runs no hooks (fetch/unbundle
    # isn't receive-pack), and the gateway being bare means there's no work
    # tree for a bundled commit's content to be checked out into here either
    # way.

    async def export_bundle(self, refspec: str) -> dict:
        """Bundle the given refs out of the gateway - `refspec` is `git
        bundle create`'s own selector argument (e.g. `--branches`), not a
        src:dst mapping. Used to send the gateway's view of the remote back
        down to the Workspace after a fetch."""
        if not self.configured:
            return {"data_b64": "", "stderr": "git-mcp is not configured", "exit_code": -1}
        result = await asyncio.to_thread(
            subprocess.run,
            self._gateway_argv("bundle", "create", "-", refspec),
            capture_output=True,
            timeout=120,
            env=self._ssh_env(),
        )
        return {
            "data_b64": base64.b64encode(result.stdout).decode("ascii"),
            "stderr": _decode(result.stderr),
            "exit_code": result.returncode,
        }

    async def import_bundle(self, data_b64: str, refspec: str) -> PushResult:
        """Absorb a bundle (base64) from the Workspace into the gateway's own
        refs, per `refspec` (a real src:dst fetch refspec, e.g.
        `+refs/heads/*:refs/heads/*`). This is how the agent's local commits
        - made via `git` in the Workspace, never here - become visible to
        push_request/push_execute below."""
        if not self.configured:
            return PushResult(stdout="", stderr="git-mcp is not configured", exit_code=-1)
        raw = base64.b64decode(data_b64) if data_b64 else b""
        if not raw:
            return PushResult(stdout="", stderr="empty bundle, nothing to import", exit_code=0)
        fd, path = tempfile.mkstemp(suffix=".bundle", dir="/tmp")
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(raw)
            result = await asyncio.to_thread(
                subprocess.run,
                self._gateway_argv("fetch", "--no-tags", path, refspec),
                capture_output=True,
                text=True,
                timeout=120,
                env=self._ssh_env(),
            )
            return PushResult(
                stdout=_decode(result.stdout),
                stderr=_decode(result.stderr),
                exit_code=result.returncode,
            )
        finally:
            os.unlink(path)

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
        # Pushes the gateway's own refs/heads/<branch> - the orchestrator's
        # harness syncs the Workspace's local branches into the gateway
        # (import_bundle above) right before calling this, so this is
        # whatever the agent's Workspace-side branch of that name currently
        # holds. Deliberate change from ADR-0003's "push HEAD:<branch>" - the
        # gateway is a bare mirror with no single checked-out HEAD to speak
        # of; the branch name is now the only thing identifying what's being
        # pushed (see docs/adr/0004-git-mcp-bundle-relay.md). If that branch
        # was never synced, git's own "src refspec does not match any"
        # error surfaces here, which is a clear enough failure mode.
        return await self._run_gateway_git(
            "push", pending.remote, f"refs/heads/{pending.branch}:refs/heads/{pending.branch}",
            timeout=120,
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
