"""Pandora Orchestrator (phase 1).

The LLM-facing harness. Built on mcp-agent, chosen because it ships with no
built-in tools (no bash, no file I/O) - everything the LLM can do goes
through an MCP server wired in explicitly. This process registers exactly
one: Workspace MCP, exposed to the LLM as the `workspace_exec` tool
(mcp-agent namespaces tools as `<server_name>_<tool_name>`, so the config
key "workspace" + Workspace MCP's `exec` tool becomes `workspace_exec`).

Chat MCP is deliberately not given to the LLM as a tool - see chat_client.py
for why. This module's job is the harness loop: wait for a human message,
ask the LLM (with workspace_exec available) to respond, relay the reply
back. See docs/adr/0001-phase-1-four-container-architecture.md and
docs/plans/phase-1-implementation-plan.md (Milestone 4).
"""

import asyncio
import os

from mcp_agent.agents.agent import Agent
from mcp_agent.app import MCPApp
from mcp_agent.logging.logger import LoggingConfig
from mcp_agent.workflows.llm.augmented_llm_anthropic import AnthropicAugmentedLLM

from .chat_client import ChatClient

SYSTEM_INSTRUCTION = """
You are Pandora's Orchestrator agent. Your only way to run commands is the
workspace_exec tool, which runs a shell command inside a fully
network-isolated sandbox container and returns its stdout, stderr and exit
code. You have no other tools and no direct shell access of your own. Use
workspace_exec whenever the human's request requires running a command,
reading files, or inspecting the workspace; otherwise answer directly.
Keep replies concise - they are shown in a chat UI.
""".strip()

app = MCPApp(name="pandora-orchestrator")


async def run() -> None:
    chat_url = os.environ.get("CHAT_MCP_URL", "http://chat-mcp:8802/mcp")
    poll_timeout = int(os.environ.get("CHAT_POLL_TIMEOUT_SECONDS", "30"))

    async with app.run() as agent_app:
        agent = Agent(
            name="pandora-orchestrator",
            instruction=SYSTEM_INSTRUCTION,
            server_names=["workspace"],
            context=agent_app.context,
        )

        async with agent, ChatClient(chat_url) as chat:
            llm = await agent.attach_llm(AnthropicAugmentedLLM)

            print("[orchestrator] ready, polling chat for messages...")
            while True:
                message = await chat.receive(poll_timeout)
                if message is None:
                    continue

                print(f"[orchestrator] received: {message!r}")
                try:
                    reply = await llm.generate_str(message)
                except Exception as exc:  # noqa: BLE001 - surface to the human, keep the loop alive
                    print(f"[orchestrator] error handling message: {exc!r}")
                    reply = f"Sorry, something went wrong handling that: {exc}"

                await chat.send(reply)
                print(f"[orchestrator] replied: {reply!r}")

    await LoggingConfig.shutdown()


def main() -> None:
    try:
        asyncio.run(run())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
