{
  description = "Pandora - sandbox environment for keeping agents in the box (phase 1: four-container skeleton)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Workspace has no application dependencies, so it builds as a pure
        # Nix package. The other three are Python services with real
        # dependency trees; see docs/adr/0001-phase-1-four-container-architecture.md
        # §3 for why they stay Dockerfile-based instead.
        workspaceImage = pkgs.callPackage ./workspace { };

        # A flake `app` runs on the host at `nix run` time (full network +
        # docker daemon access), unlike a `packages.*` derivation, which is
        # sandboxed and must stay pure - that's what makes shelling out to
        # `docker build` here a legitimate, reversible choice rather than an
        # impurity smuggled into the package graph.
        dockerBuildApp = name: dir: tag: {
          type = "app";
          program = toString (pkgs.writeShellScript "build-${name}-image" ''
            set -euo pipefail
            exec ${pkgs.docker}/bin/docker build -t ${tag} ${dir}
          '');
        };
      in
      {
        packages = {
          workspace-image = workspaceImage;
          default = workspaceImage;
        };

        apps = {
          build-workspace-mcp-image = dockerBuildApp "workspace-mcp" ./workspace-mcp "pandora-workspace-mcp:dev";
          build-chat-mcp-image = dockerBuildApp "chat-mcp" ./chat-mcp "pandora-chat-mcp:dev";
          build-orchestrator-image = dockerBuildApp "orchestrator" ./orchestrator "pandora-orchestrator:dev";

          up = {
            type = "app";
            program = toString (pkgs.writeShellScript "pandora-up" ''
              echo "apps.up: not implemented yet (lands in Milestone 5 - see docs/plans/phase-1-implementation-plan.md)" >&2
              exit 1
            '');
          };
        };

        devShells.default = pkgs.mkShell {
          packages = [ pkgs.docker pkgs.docker-compose pkgs.python3 ];
        };
      });
}
