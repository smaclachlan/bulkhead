{
  description = "Bulkhead - sandbox environment for keeping agents in the box (phase 1: four-container skeleton)";

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
              echo "run this from the bulkhead repo root (flake.nix not found in $PWD)" >&2
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
          build-workspace-mcp-image = dockerBuildApp "workspace-mcp" "workspace-mcp" "bulkhead-workspace-mcp:dev";
          build-chat-mcp-image = dockerBuildApp "chat-mcp" "chat-mcp" "bulkhead-chat-mcp:dev";
          build-orchestrator-image = dockerBuildApp "orchestrator" "orchestrator" "bulkhead-orchestrator:dev";
          build-memory-mcp-image = dockerBuildApp "memory-mcp" "memory-mcp" "bulkhead-memory-mcp:dev";
          build-git-mcp-image = dockerBuildApp "git-mcp" "git-mcp" "bulkhead-git-mcp:dev";

          # Terminal client for Chat MCP's REST API (docs/adr/0002-phase-2-isolation-ux-memory.md,
          # phase-2-scope.md item 3) - a third consumer of the same
          # /api/messages, /api/send surface the browser UI uses, so it
          # needs no image build of its own, just the devShell's python3.
          # Usage: nix run .#chat                  # drops straight into a
          #                                         # persistent live chat
          #        nix run .#chat -- send "hi" --wait
          # (reads CHAT_MCP_TOKEN/CHAT_UI_URL from the environment if set;
          # otherwise pulls the token straight out of
          # `docker compose logs chat-mcp` itself, so this works with no
          # setup beyond the stack being up.)
          chat = {
            type = "app";
            program = toString (pkgs.writeShellScript "bulkhead-chat" ''
              set -euo pipefail
              if [ ! -f flake.nix ]; then
                echo "run this from the bulkhead repo root (flake.nix not found in $PWD)" >&2
                exit 1
              fi
              exec ${pkgs.python3}/bin/python3 chat-mcp/src/chat_mcp/cli.py "$@"
            '');
          };

          up = {
            type = "app";
            program = toString (pkgs.writeShellScript "bulkhead-up" ''
              set -euo pipefail
              if [ ! -f flake.nix ] || [ ! -f docker-compose.yml ]; then
                echo "run this from the bulkhead repo root (flake.nix/docker-compose.yml not found in $PWD)" >&2
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

              echo "== Building workspace-mcp, chat-mcp, orchestrator, memory-mcp, git-mcp images via Docker ==" >&2
              ${pkgs.docker}/bin/docker build $no_cache -t bulkhead-workspace-mcp:dev workspace-mcp
              ${pkgs.docker}/bin/docker build $no_cache -t bulkhead-chat-mcp:dev chat-mcp
              ${pkgs.docker}/bin/docker build $no_cache -t bulkhead-orchestrator:dev orchestrator
              ${pkgs.docker}/bin/docker build $no_cache -t bulkhead-memory-mcp:dev memory-mcp
              ${pkgs.docker}/bin/docker build $no_cache -t bulkhead-git-mcp:dev git-mcp

              echo "== Starting docker compose (detached) ==" >&2
              ${pkgs.docker-compose}/bin/docker-compose up -d

              # git-mcp-unlock self-skips when there's nothing to unlock
              # (unconfigured / already cloned / passphrase-less key), so
              # it's safe to always call it here rather than making that a
              # manual step - only a real passphrase-protected key ever
              # actually prompts. Poll briefly first since `up -d` returns
              # as soon as containers start, not once git-mcp's own ssh-agent
              # has finished coming up (see state.py's _start_agent).
              echo "== Checking whether git-mcp's deploy key needs a passphrase ==" >&2
              attempt=0
              while ! ${pkgs.docker-compose}/bin/docker-compose exec -T git-mcp \
                  test -S /tmp/git-mcp-agent.sock >/dev/null 2>&1; do
                attempt=$((attempt + 1))
                if [ "$attempt" -ge 20 ]; then
                  echo "git-mcp not ready yet - run 'nix run .#git-unlock' manually once it is" >&2
                  break
                fi
                sleep 0.5
              done
              # Real pty here (no -T) so git-mcp-unlock's `stty -echo` prompt
              # works; a failed/declined/unnecessary unlock shouldn't fail
              # `up` itself, hence the `|| true`.
              ${pkgs.docker-compose}/bin/docker-compose exec git-mcp git-mcp-unlock || true

              # chat-mcp prints its (freshly-generated-per-boot, unless
              # CHAT_MCP_TOKEN is pinned in .env) URL+token to its own stdout
              # once at startup - server.py's _resolve_token/`_run`. With
              # `up` foregrounded that used to scroll past on screen for
              # free; detached, it only lives in `docker compose logs
              # chat-mcp` (same place chat-mcp/src/chat_mcp/cli.py's
              # _discover_token already looks), so fetch and print it here
              # instead of leaving that as a manual step too.
              chat_line=""
              attempt=0
              while [ -z "$chat_line" ]; do
                # `|| true`: grep exits 1 on no match yet (expected on early
                # attempts), which pipefail would otherwise propagate and
                # trip `set -e`, aborting this whole script.
                chat_line="$(${pkgs.docker-compose}/bin/docker-compose logs chat-mcp 2>/dev/null \
                  | grep -o 'chat UI: http://[^[:space:]]*' | tail -n1 || true)"
                [ -n "$chat_line" ] && break
                attempt=$((attempt + 1))
                if [ "$attempt" -ge 20 ]; then
                  echo "chat-mcp hasn't printed its URL yet - check 'docker compose logs chat-mcp'" >&2
                  break
                fi
                sleep 0.5
              done

              echo "== Stack is up. 'docker compose logs -f <service>' to tail logs;" >&2
              [ -n "$chat_line" ] && echo "   $chat_line" >&2
              echo "   're-run nix run .#git-unlock' any time (e.g. after a git-mcp restart);" >&2
              echo "   'nix run .#down' to stop it. ==" >&2
            '');
          };

          # `up` now runs detached (see above), so there's no foreground
          # process left to Ctrl+C - this is the counterpart to bring it down.
          down = {
            type = "app";
            program = toString (pkgs.writeShellScript "bulkhead-down" ''
              set -euo pipefail
              if [ ! -f flake.nix ] || [ ! -f docker-compose.yml ]; then
                echo "run this from the bulkhead repo root (flake.nix/docker-compose.yml not found in $PWD)" >&2
                exit 1
              fi
              exec ${pkgs.docker-compose}/bin/docker-compose down
            '');
          };

          # Loads a passphrase into git-mcp's own ssh-agent (see
          # git-mcp/git-mcp-unlock and state.py's _start_agent) - needed
          # because docker-compose.yml's git-mcp has no way to read a
          # passphrase at cold-boot: `up`'s (now backgrounded, see above)
          # merged multi-service log stream never wires host stdin into any
          # one container, and forwarding a host ssh-agent socket in doesn't
          # survive a future Kata/Apple-containerization move of git-mcp
          # (docs/adr/0003-phase-3-git-mcp.md follow-ups) since that crosses
          # a kernel boundary an AF_UNIX socket can't cross. `docker compose
          # exec` opens its own independent pty to the container regardless
          # of how `up` was started, so this works any time git-mcp is up.
          # Usage: nix run .#git-unlock
          git-unlock = {
            type = "app";
            program = toString (pkgs.writeShellScript "bulkhead-git-unlock" ''
              set -euo pipefail
              if [ ! -f flake.nix ] || [ ! -f docker-compose.yml ]; then
                echo "run this from the bulkhead repo root (flake.nix/docker-compose.yml not found in $PWD)" >&2
                exit 1
              fi
              exec ${pkgs.docker-compose}/bin/docker-compose exec git-mcp git-mcp-unlock
            '');
          };
        };

        devShells.default = pkgs.mkShell {
          packages = [ pkgs.docker pkgs.docker-compose pkgs.python3 ];
        };
      });
}
