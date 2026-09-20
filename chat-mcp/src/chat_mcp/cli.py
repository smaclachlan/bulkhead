"""Terminal client for Chat MCP.

A third consumer of the REST surface web.py already exposes for the browser
UI (/api/messages, /api/send) - no new container, no new network path, no
change to any containment boundary. See
docs/adr/0002-phase-2-isolation-ux-memory.md's Context (why this item needs
no decision record of its own) and Testing & Validation section.

Usage:
    python -m chat_mcp.cli                         # drop straight into a
                                                     # persistent chat (same
                                                     # as `... repl`)
    python -m chat_mcp.cli send "message" [--wait] [--timeout SECONDS]

Reads CHAT_MCP_TOKEN and CHAT_UI_URL (default http://localhost:8787) from
the environment; both can also be passed as --token/--url. If no token is
available either way, falls back to pulling the most recent one out of
`docker compose logs chat-mcp` (same place a human would otherwise have to
copy it from by hand) - run from the repo root, with the stack up.

Against a non-default concurrent profile (see README's "Workspace image and
concurrent profiles"), pass --env-file with the same profile path used to
bring that stack up - this derives the right project name (for the
docker-compose lookup above) and CHAT_UI_HOST_PORT the same way
`nix run .#up`/`down`/`git-unlock`/the validate-*.sh scripts do (see
scripts/lib/profile.sh), instead of silently defaulting to the wrong
stack's port. Explicit --url/--token/env vars still take precedence over
anything derived from --env-file.

`repl` polls for new messages on a background thread, so a reply can appear
while you're mid-way through typing the next line - unlike a plain
request/response loop, this is a live view of the conversation, the same
one the browser UI shows. The trade-off of doing this with nothing but the
stdlib (no curses/readline dependency) is cosmetic: an incoming line can
interleave with a line you're still typing. Nothing is lost - your input
buffer is untouched - it just looks momentarily messy; press Enter and the
prompt reappears cleanly.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

PROMPT = "> "

# Orchestrator strips these by default (CHAT_SHOW_TOOL_CALLS off) - only
# present at all when that flag is set, in which case mcp-agent's own
# "[Calling tool X with args Y]" notices are left in the message text as-is
# (see orchestrator/src/orchestrator/main.py). Rendered here in ANSI
# italics, same distinction the browser UI draws via CSS, so they read as
# internal plumbing rather than part of the actual reply.
_TOOL_CALL_LINE = re.compile(r"^\[Calling tool .*\]$")
_ITALIC, _RESET = "\033[3m", "\033[0m"


def _format_reply(text: str) -> str:
    return "\n".join(
        f"{_ITALIC}{line}{_RESET}" if _TOOL_CALL_LINE.match(line) else line
        for line in text.split("\n")
    )


def _format_ts(ts: float) -> str:
    return time.strftime("%H:%M:%S", time.localtime(ts))


# Same wording/status set the browser UI's ACTIVITY_LABELS uses (index.html)
# - both read straight off /api/status, no separate signal.
_ACTIVITY_LABELS = {
    "received": "agent received your message...",
    "working": "agent is working...",
    "error": "agent hit an error",
}


def _url(base: str, path: str, token: str) -> str:
    sep = "&" if "?" in path else "?"
    return f"{base}{path}{sep}token={token}"


def _get(base: str, path: str, token: str) -> dict:
    with urllib.request.urlopen(_url(base, path, token), timeout=10) as resp:
        return json.load(resp)


def _post(base: str, path: str, token: str, body: dict) -> dict:
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        _url(base, path, token), data=data, headers={"content-type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.load(resp)


def _resolve_profile(env_file: str) -> dict | None:
    """Resolve project name / CHAT_UI_HOST_PORT for env_file the same way
    flake.nix's up/down/git-unlock apps and scripts/validate-*.sh do - see
    scripts/lib/profile.sh, the single source of truth for this derivation.
    Must be run from the repo root (same existing constraint as
    `nix run .#chat`/_discover_token's bare `docker compose logs` below).
    Returns None on any failure (wrong cwd, bad env file, etc.)."""
    script = (
        'set -a; . "$1"; set +a; . scripts/lib/profile.sh; '
        'bulkhead_resolve_profile "$1" || exit 1; '
        'printf "%s\\t%s\\n" "$BULKHEAD_PROJECT_NAME" "${CHAT_UI_HOST_PORT:-8787}"'
    )
    try:
        result = subprocess.run(
            ["sh", "-c", script, "sh", env_file],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0 or not result.stdout.strip():
        return None
    project, port = result.stdout.strip().split("\t")
    return {"project": project, "port": port}


def _discover_token(project_name: str | None = None, env_file: str | None = None) -> str:
    """Best-effort fallback: pull the most recent token out of chat-mcp's own
    logs, the same place a human would otherwise copy it from by hand. Only
    works from the repo root with the stack up - silently returns "" on any
    failure so the caller can give one clear error message instead of a
    confusing subprocess traceback. project_name/env_file (from --env-file)
    scope the lookup to a specific concurrent profile's stack instead of
    always assuming the default one."""
    cmd = ["docker", "compose"]
    if project_name:
        cmd += ["-p", project_name, "--env-file", env_file]
    cmd += ["logs", "chat-mcp"]
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    matches = re.findall(r"token=([A-Za-z0-9_-]+)", result.stdout)
    return matches[-1] if matches else ""


def cmd_send(args: argparse.Namespace, base: str, token: str) -> None:
    result = _post(base, "/api/send", token, {"text": args.text})
    if not args.wait:
        return

    since = result["id"]
    deadline = time.time() + args.timeout
    # Status notices go to stderr, not stdout - keeps stdout exclusively the
    # final reply text (e.g. `nix run .#chat -- send "hi" --wait > reply.txt`
    # stays clean), and this is otherwise silent for up to --timeout with no
    # sign anything is happening.
    last_status = None
    while time.time() < deadline:
        try:
            status = _get(base, "/api/status", token).get("status")
        except (urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError):
            status = None
        if status != last_status and _ACTIVITY_LABELS.get(status):
            print(f"({_ACTIVITY_LABELS[status]})", file=sys.stderr)
        last_status = status

        data = _get(base, f"/api/messages?since={since}", token)
        for m in data["messages"]:
            since = max(since, m["id"])
            if m["role"] != "user":
                print(f"[{_format_ts(m['ts'])}] {_format_reply(m['text'])}")
                return
        time.sleep(1)

    print("(timed out waiting for a reply)", file=sys.stderr)
    sys.exit(1)


def _poll_loop(base: str, token: str, since: "list[int]", stop: threading.Event) -> None:
    """Background thread: prints new agent replies as they arrive,
    independent of whether the user is mid-input. Skips user messages - the
    terminal's own line echo already showed those when typed. `since` is a
    1-element list used as a mutable box so this thread and the main thread
    share one cursor without needing a lock for a single int assignment.

    Also polls /api/status on the same cadence and prints a one-line notice
    on each status change (received/working/error) - same signal the
    browser UI's activity indicator shows, just as transition lines instead
    of a continuously-updated one, matching how new messages are already
    printed here rather than attempting an in-place-updating spinner: this
    thread runs concurrently with the main thread's blocking `input()`
    prompt, so redrawing a single line in place would fight the prompt's
    own redraw rather than just interleaving with it (see this module's own
    docstring on that trade-off)."""
    last_status = None
    while not stop.is_set():
        try:
            data = _get(base, f"/api/messages?since={since[0]}", token)
            for m in data["messages"]:
                since[0] = max(since[0], m["id"])
                if m["role"] == "user":
                    continue
                print(
                    f"\n[agent {_format_ts(m['ts'])}] {_format_reply(m['text'])}\n{PROMPT}",
                    end="", flush=True,
                )
        except (urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError):
            pass  # transient - the next poll retries; don't kill the thread over one bad response

        try:
            status = _get(base, "/api/status", token).get("status")
        except (urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError):
            status = None
        if status != last_status and _ACTIVITY_LABELS.get(status):
            print(f"\n({_ACTIVITY_LABELS[status]})\n{PROMPT}", end="", flush=True)
        last_status = status

        stop.wait(1.0)


def cmd_repl(args: argparse.Namespace, base: str, token: str) -> None:
    since = [0]
    stop = threading.Event()
    poller = threading.Thread(target=_poll_loop, args=(base, token, since, stop), daemon=True)
    poller.start()

    print(f"connected to {base} - Ctrl-D to exit")
    try:
        while True:
            try:
                line = input(PROMPT)
            except (EOFError, KeyboardInterrupt):
                print()
                return
            if line.strip():
                _post(base, "/api/send", token, {"text": line})
    finally:
        stop.set()


def main() -> None:
    parser = argparse.ArgumentParser(prog="bulkhead-chat")
    parser.add_argument("--url", default=os.environ.get("CHAT_UI_URL", ""))
    parser.add_argument("--token", default=os.environ.get("CHAT_MCP_TOKEN", ""))
    parser.add_argument(
        "--env-file",
        default=None,
        help="profile env-file to target (same one passed to `nix run .#up`/`down`/"
        "`git-unlock` for that stack) - derives the right project/port instead of "
        "defaulting to the default stack's",
    )
    sub = parser.add_subparsers(dest="command")

    p_send = sub.add_parser("send", help="send one message")
    p_send.add_argument("text")
    p_send.add_argument("--wait", action="store_true", help="wait for and print the next reply")
    p_send.add_argument("--timeout", type=float, default=60.0)
    p_send.set_defaults(func=cmd_send)

    p_repl = sub.add_parser("repl", help="persistent terminal chat (the default)")
    p_repl.set_defaults(func=cmd_repl)

    args = parser.parse_args()
    if args.command is None:
        args.func = cmd_repl

    profile = None
    if args.env_file:
        profile = _resolve_profile(args.env_file)
        if profile is None:
            print(
                f"error: could not resolve profile '{args.env_file}' - run this "
                "from the repo root",
                file=sys.stderr,
            )
            sys.exit(2)

    base_url = args.url or (f"http://localhost:{profile['port']}" if profile else "http://localhost:8787")
    token = args.token or _discover_token(
        profile["project"] if profile else None, args.env_file
    )
    if not token:
        print(
            "error: no chat-mcp token found - pass --token, set CHAT_MCP_TOKEN, "
            "or run this from the repo root with the stack up so it can be read "
            "from `docker compose logs chat-mcp`",
            file=sys.stderr,
        )
        sys.exit(2)

    try:
        args.func(args, base_url, token)
    except urllib.error.HTTPError as exc:
        print(f"HTTP error: {exc.code} {exc.reason}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as exc:
        print(f"connection error: {exc.reason}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
