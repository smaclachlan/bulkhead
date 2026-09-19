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
            no_cache=""
            if [ "''${1:-}" = "--no-cache" ]; then
              no_cache="--no-cache"
            fi
            exec ${pkgs.docker}/bin/docker build $no_cache -t ${tag} ${dir}
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
          build-memory-mcp-image = dockerBuildApp "memory-mcp" "memory-mcp" "pandora-memory-mcp:dev";

          # Terminal client for Chat MCP's REST API (docs/adr/0002-phase-2-isolation-ux-memory.md,
          # phase-2-scope.md item 3) - a third consumer of the same
          # /api/messages, /api/send surface the browser UI uses, so it
          # needs no image build of its own, just the devShell's python3.
          # Usage: nix run .#chat -- send "hi" --wait
          #        nix run .#chat -- repl
          # (reads CHAT_MCP_TOKEN/CHAT_UI_URL from the environment; the
          # token is printed by `docker compose logs chat-mcp`.)
          chat = {
            type = "app";
            program = toString (pkgs.writeShellScript "pandora-chat" ''
              set -euo pipefail
              if [ ! -f flake.nix ]; then
                echo "run this from the pandora repo root (flake.nix not found in $PWD)" >&2
                exit 1
              fi
              exec ${pkgs.python3}/bin/python3 chat-mcp/src/chat_mcp/cli.py "$@"
            '');
          };

          up = {
            type = "app";
            program = toString (pkgs.writeShellScript "pandora-up" ''
              set -euo pipefail
              if [ ! -f flake.nix ] || [ ! -f docker-compose.yml ]; then
                echo "run this from the pandora repo root (flake.nix/docker-compose.yml not found in $PWD)" >&2
                exit 1
              fi

              no_cache=""
              if [ "''${1:-}" = "--no-cache" ]; then
                no_cache="--no-cache"
                echo "== --no-cache requested: Docker image layers will not be reused ==" >&2
              fi

              echo "== Building workspace-image via Nix ==" >&2
              result_link="$(mktemp -u)"
              ${pkgs.nix}/bin/nix build .#workspace-image -o "$result_link"
              ${pkgs.docker}/bin/docker load < "$result_link"
              rm -f "$result_link"

              echo "== Building workspace-mcp, chat-mcp, orchestrator, memory-mcp images via Docker ==" >&2
              ${pkgs.docker}/bin/docker build $no_cache -t pandora-workspace-mcp:dev workspace-mcp
              ${pkgs.docker}/bin/docker build $no_cache -t pandora-chat-mcp:dev chat-mcp
              ${pkgs.docker}/bin/docker build $no_cache -t pandora-orchestrator:dev orchestrator
              ${pkgs.docker}/bin/docker build $no_cache -t pandora-memory-mcp:dev memory-mcp

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
