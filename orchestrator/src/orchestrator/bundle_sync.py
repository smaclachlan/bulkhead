"""Harness-level `git bundle` relay between the Workspace's /repo and Git
MCP's gateway mirror - see docs/adr/0004-git-mcp-bundle-relay.md.

Neither container can reach the other directly (no network between
workspace-mcp and git-mcp, deliberately - see that ADR's "why the
orchestrator relays, not a new network"), so main.py's harness loop calls
these two functions instead, using the two hand-rolled admin clients that
are already never given to the LLM. Bundle bytes never pass through
`llm.generate_str` - the LLM has no field to see or influence them.
"""

from .git_admin_client import GitAdminClient
from .workspace_admin_client import WorkspaceAdminClient

# git bundle create's own selector, not a fetch refspec - "every local
# branch", matching what push_request/push_execute care about (README's
# Egress section never gated tags, and there's no LLM tool to create one).
_EXPORT_SELECTOR = "--branches"


def _bundle_is_empty(export_result: dict) -> bool:
    # `git bundle create` exits non-zero ("Refusing to create empty bundle")
    # when nothing matches the selector yet - e.g. before the agent's first
    # commit. Not an error state, just nothing to relay this round.
    return export_result.get("exit_code", -1) != 0 or not export_result.get("data_b64")


async def sync_to_gateway(workspace_admin: WorkspaceAdminClient, git_admin: GitAdminClient) -> None:
    """Workspace's local branches -> git-mcp's gateway. Run before staging
    or executing a push, so push_request/push_execute act on what the agent
    actually committed in the Workspace, not a stale snapshot."""
    exported = await workspace_admin.export_bundle(_EXPORT_SELECTOR)
    if _bundle_is_empty(exported):
        return
    await git_admin.import_bundle(exported["data_b64"], "+refs/heads/*:refs/heads/*")


async def sync_to_workspace(workspace_admin: WorkspaceAdminClient, git_admin: GitAdminClient) -> None:
    """git-mcp's gateway -> the Workspace's remote-tracking refs. Run after
    a turn that may have called git_fetch, so the agent's next `git log`/
    `git checkout` via workspace_exec can see what was fetched. Lands under
    refs/remotes/origin/*, never refs/heads/* - this must never silently
    move a local branch the agent has checked out."""
    exported = await git_admin.export_bundle(_EXPORT_SELECTOR)
    if _bundle_is_empty(exported):
        return
    await workspace_admin.import_bundle(
        exported["data_b64"], "+refs/heads/*:refs/remotes/origin/*"
    )
