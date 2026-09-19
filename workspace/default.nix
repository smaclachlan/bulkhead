{ dockerTools, coreutils, bashInteractive, ... }:

# Phase 1 Workspace image: nothing but a shell and coreutils, no network,
# no MCP client, no credentials. It is a pure `docker exec` target - see
# docs/adr/0001-phase-1-four-container-architecture.md and
# docs/plans/phase-1-implementation-plan.md (Milestone 1).
dockerTools.buildLayeredImage {
  name = "pandora-workspace";
  tag = "dev";

  contents = [ coreutils bashInteractive ];

  config = {
    Cmd = [ "/bin/sh" "-c" "sleep infinity" ];
  };
}
