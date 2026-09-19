# Source this; do not execute directly. Single source of truth for deriving
# a profile's project name / workspace container name / workspace image tag
# from its env-file path - consumed by flake.nix's up/down/git-unlock apps
# (previously 3 independent copies of this same derivation), the
# validate-phase2.sh/validate-phase3.sh scripts, check-mcp-allowlist.sh, and
# chat_mcp/cli.py, so every consumer resolves a given profile identically.
# POSIX sh only (no `local`, no arrays) - these scripts are invoked via
# `sh scripts/validate-phaseN.sh`, not bash. Run with cwd == repo root, same
# constraint flake.nix's own apps already document and enforce.

bulkhead_resolve_profile() {
  BULKHEAD_ENV_FILE="${1:-.env}"
  if [ ! -f "$BULKHEAD_ENV_FILE" ]; then
    echo "env file '$BULKHEAD_ENV_FILE' not found" >&2
    return 1
  fi
  if [ "$BULKHEAD_ENV_FILE" = ".env" ]; then
    BULKHEAD_PROJECT_NAME="bulkhead"
  else
    BULKHEAD_PROJECT_NAME="$(basename "$BULKHEAD_ENV_FILE" | sed 's/\.[^.]*$//' \
      | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-')"
  fi
  BULKHEAD_WORKSPACE_CONTAINER_NAME="${BULKHEAD_PROJECT_NAME}-workspace"
  # Only the workspace image varies per profile (WORKSPACE_DOCKERFILE_DIR is
  # the whole point of a second profile - a different project's toolchain).
  # workspace-mcp/chat-mcp/orchestrator/memory-mcp/git-mcp are Bulkhead's own
  # control-plane images, always built from this one checkout regardless of
  # profile, so every profile produces identical content for those five and
  # sharing their tags is correct, not a collision - see README's "Workspace
  # image and concurrent profiles" section.
  if [ "$BULKHEAD_PROJECT_NAME" = "bulkhead" ]; then
    BULKHEAD_WORKSPACE_IMAGE="bulkhead-workspace:dev"
  else
    BULKHEAD_WORKSPACE_IMAGE="bulkhead-workspace:${BULKHEAD_PROJECT_NAME}"
  fi
}
