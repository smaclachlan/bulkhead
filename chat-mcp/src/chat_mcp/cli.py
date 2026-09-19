"""Terminal client for Chat MCP.

A third consumer of the REST surface web.py already exposes for the browser
UI (/api/messages, /api/send) - no new container, no new network path, no
change to any containment boundary. See
docs/adr/0002-phase-2-isolation-ux-memory.md's Context (why this item needs
no decision record of its own) and Testing & Validation section.

Usage:
    python -m chat_mcp.cli repl
    python -m chat_mcp.cli send "message" [--wait] [--timeout SECONDS]

Reads CHAT_MCP_TOKEN and CHAT_UI_URL (default http://localhost:8787) from
the environment; both can also be passed as --token/--url.
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request


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


def cmd_repl(args: argparse.Namespace, base: str, token: str) -> None:
    since = 0
    print(f"connected to {base} - Ctrl-D to exit")
    while True:
        data = _get(base, f"/api/messages?since={since}", token)
        for m in data["messages"]:
            since = max(since, m["id"])
            prefix = "you" if m["role"] == "user" else "agent"
            print(f"[{prefix}] {m['text']}")
        try:
            line = input("> ")
        except EOFError:
            print()
            return
        except KeyboardInterrupt:
            print()
            return
        if line.strip():
            _post(base, "/api/send", token, {"text": line})


def main() -> None:
    parser = argparse.ArgumentParser(prog="pandora-chat")
    parser.add_argument("--url", default=os.environ.get("CHAT_UI_URL", "http://localhost:8787"))
    parser.add_argument("--token", default=os.environ.get("CHAT_MCP_TOKEN", ""))
    sub = parser.add_subparsers(dest="command", required=True)

    p_send = sub.add_parser("send", help="send one message")
    p_send.add_argument("text")
    p_send.add_argument("--wait", action="store_true", help="wait for and print the next reply")
    p_send.add_argument("--timeout", type=float, default=60.0)
    p_send.set_defaults(func=cmd_send)

    p_repl = sub.add_parser("repl", help="persistent terminal chat")
    p_repl.set_defaults(func=cmd_repl)

    args = parser.parse_args()
    if not args.token:
        print("error: --token or CHAT_MCP_TOKEN is required", file=sys.stderr)
        sys.exit(2)

    try:
        args.func(args, args.url, args.token)
    except urllib.error.HTTPError as exc:
        print(f"HTTP error: {exc.code} {exc.reason}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as exc:
        print(f"connection error: {exc.reason}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
