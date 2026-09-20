{ dockerTools, coreutils, bashInteractive, git, ... }:

# Phase 1 Workspace image: shell, coreutils, and git - no MCP client, no
# credentials. It is a pure `docker exec` target - see
# docs/adr/0001-phase-1-four-container-architecture.md and
# docs/plans/phase-1-implementation-plan.md (Milestone 1).
#
# git was added in docs/adr/0004-git-mcp-bundle-relay.md: local git
# operations (and any hooks they trigger) now run here, not in git-mcp -
# this is the fully network-isolated, disposable side of the boundary, so a
# malicious hook has a contained shell to run in and nothing to reach. The
# deploy key and the network path to the remote never come anywhere near
# this image; git-mcp exchanges plain `git bundle` files with it (via
# workspace-mcp's admin port) instead of sharing a git directory.
dockerTools.buildLayeredImage {
  name = "bulkhead-workspace";
  tag = "dev";

  contents = [ coreutils bashInteractive git ];

  # Non-root, belt-and-braces on top of this container's real containment
  # (no network, optional Kata microVM). Numeric UID:GID only, no /etc/passwd
  # entry - nothing here needs a resolvable username. Only covers the
  # default WORKSPACE_REPO_PATH (/repo); a custom one needs its own chown.
  enableFakechroot = true;
  fakeRootCommands = ''
    mkdir -p /repo /tmp
    chown 10001:10001 /repo
    chmod 1777 /tmp
  '';

  config = {
    Cmd = [ "/bin/sh" "-c" "sleep infinity" ];
    User = "10001:10001";
    # `git commit`/hooks need an author identity; there's no human to run
    # `git config` interactively in here, and no on-disk gitconfig is set up
    # by default - GIT_AUTHOR_*/GIT_COMMITTER_* env vars satisfy git without
    # either. Previously set on git-mcp's own Dockerfile (pre-ADR-0004, when
    # commits happened there); moved here with the commits themselves.
    Env = [
      "GIT_AUTHOR_NAME=Bulkhead Agent"
      "GIT_AUTHOR_EMAIL=bulkhead-agent@localhost"
      "GIT_COMMITTER_NAME=Bulkhead Agent"
      "GIT_COMMITTER_EMAIL=bulkhead-agent@localhost"
      # No passwd entry to resolve a home dir from (see above) - point it
      # somewhere writable so tools that assume $HOME exists don't fail.
      "HOME=/repo"
    ];
  };
}
