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


def _discover_token() -> str:
    """Best-effort fallback: pull the most recent token out of chat-mcp's own
    logs, the same place a human would otherwise copy it from by hand. Only
    works from the repo root with the stack up - silently returns "" on any
    failure so the caller can give one clear error message instead of a
    confusing subprocess traceback."""
    try:
        result = subprocess.run(
            ["docker", "compose", "logs", "chat-mcp"],
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
    while time.time() < deadline:
        data = _get(base, f"/api/messages?since={since}", token)
        for m in data["messages"]:
            since = max(since, m["id"])
            if m["role"] != "user":
                print(m["text"])
                return
        time.sleep(1)

    print("(timed out waiting for a reply)", file=sys.stderr)
    sys.exit(1)


def _poll_loop(base: str, token: str, since: "list[int]", stop: threading.Event) -> None:
    """Background thread: prints new messages (either side - matches the
    browser UI's own always-reprint-the-transcript behaviour) as they
    arrive, independent of whether the user is mid-input. `since` is a
    1-element list used as a mutable box so this thread and the main thread
    share one cursor without needing a lock for a single int assignment."""
    while not stop.is_set():
        try:
            data = _get(base, f"/api/messages?since={since[0]}", token)
            for m in data["messages"]:
                since[0] = max(since[0], m["id"])
                prefix = "you" if m["role"] == "user" else "agent"
                print(f"\n[{prefix}] {m['text']}\n{PROMPT}", end="", flush=True)
        except (urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError):
            pass  # transient - the next poll retries; don't kill the thread over one bad response
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
    parser = argparse.ArgumentParser(prog="axle-chat")
    parser.add_argument("--url", default=os.environ.get("CHAT_UI_URL", "http://localhost:8787"))
    parser.add_argument("--token", default=os.environ.get("CHAT_MCP_TOKEN", ""))
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

    token = args.token or _discover_token()
    if not token:
        print(
            "error: no chat-mcp token found - pass --token, set CHAT_MCP_TOKEN, "
            "or run this from the repo root with the stack up so it can be read "
            "from `docker compose logs chat-mcp`",
            file=sys.stderr,
        )
        sys.exit(2)

    try:
        args.func(args, args.url, token)
    except urllib.error.HTTPError as exc:
        print(f"HTTP error: {exc.code} {exc.reason}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as exc:
        print(f"connection error: {exc.reason}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
