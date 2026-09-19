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
        #
        # These apps deliberately use plain relative paths (not `${./dir}`
        # Nix-path interpolation, which would copy a snapshot into the Nix
        # store) so `docker build`/`docker compose` always see the live
        # working tree - including a Dockerfile edit you haven't committed
        # yet - and so `.env` resolves normally against the caller's cwd.
        # That means these apps must be run from the repo root.
        dockerBuildApp = name: dir: tag: {
          type = "app";
          program = toString (pkgs.writeShellScript "build-${name}-image" ''
            set -euo pipefail
            if [ ! -f flake.nix ]; then
              echo "run this from the pandora repo root (flake.nix not found in $PWD)" >&2
              exit 1
            fi
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
          build-workspace-mcp-image = dockerBuildApp "workspace-mcp" "workspace-mcp" "pandora-workspace-mcp:dev";
          build-chat-mcp-image = dockerBuildApp "chat-mcp" "chat-mcp" "pandora-chat-mcp:dev";
          build-orchestrator-image = dockerBuildApp "orchestrator" "orchestrator" "pandora-orchestrator:dev";

          up = {
            type = "app";
            program = toString (pkgs.writeShellScript "pandora-up" ''
              set -euo pipefail
              if [ ! -f flake.nix ] || [ ! -f docker-compose.yml ]; then
                echo "run this from the pandora repo root (flake.nix/docker-compose.yml not found in $PWD)" >&2
                exit 1
              fi

              echo "== Building workspace-image via Nix ==" >&2
              result_link="$(mktemp -u)"
              ${pkgs.nix}/bin/nix build .#workspace-image -o "$result_link"
              ${pkgs.docker}/bin/docker load < "$result_link"
              rm -f "$result_link"

              echo "== Building workspace-mcp, chat-mcp, orchestrator images via Docker ==" >&2
              ${pkgs.docker}/bin/docker build -t pandora-workspace-mcp:dev workspace-mcp
              ${pkgs.docker}/bin/docker build -t pandora-chat-mcp:dev chat-mcp
              ${pkgs.docker}/bin/docker build -t pandora-orchestrator:dev orchestrator

              echo "== Starting docker compose ==" >&2
              exec ${pkgs.docker-compose}/bin/docker-compose up
            '');
          };
        };

        devShells.default = pkgs.mkShell {
          packages = [ pkgs.docker pkgs.docker-compose pkgs.python3 ];
        };
      });
}
