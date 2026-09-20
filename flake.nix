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
          #        nix run .#chat -- --env-file ./second.conf send "hi" --wait
          # (reads CHAT_MCP_TOKEN/CHAT_UI_URL from the environment if set;
          # otherwise pulls the token straight out of
          # `docker compose logs chat-mcp` itself, so this works with no
          # setup beyond the stack being up. Against a non-default profile,
          # pass --env-file so it derives the right port/project instead of
          # defaulting to localhost:8787/the default stack's logs - see
          # chat_mcp/cli.py.)
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

              # Any argument that isn't --no-cache is a path to an alternate
              # env file (a "profile") to use instead of .env - same
              # KEY=value format, just a different bundle of
              # WORKSPACE_DOCKERFILE_DIR/WORKSPACE_REPO_PATH/
              # GIT_SSH_DEPLOY_KEY_HOST_PATH/etc, e.g. for a second project's
              # workspace setup: `nix run .#up -- ./rust-build.conf`. Profiles
              # can run fully concurrently, not just switch between: each one
              # resolves (via scripts/lib/profile.sh) to its own Compose
              # project name, workspace container name, and workspace image
              # tag, so two profiles never collide on a container/network/
              # volume name or on the one image tag that's allowed to differ
              # per profile. `down`/`git-unlock` still need the same profile
              # path to target the right stack.
              no_cache=""
              env_file=".env"
              for arg in "$@"; do
                case "$arg" in
                  --no-cache)
                    no_cache="--no-cache"
                    echo "== --no-cache requested: Docker image layers will not be reused ==" >&2
                    ;;
                  *)
                    env_file="$arg"
                    ;;
                esac
              done
              if [ ! -f "$env_file" ]; then
                echo "env file '$env_file' not found" >&2
                exit 1
              fi
              echo "== Using env file: $env_file ==" >&2
              set -a
              . "$env_file"
              set +a

              # scripts/lib/profile.sh is the single source of truth for
              # this derivation - also used by down/git-unlock below and by
              # the validate-*.sh/check-mcp-allowlist.sh scripts, so every
              # consumer resolves a given profile identically.
              . scripts/lib/profile.sh
              bulkhead_resolve_profile "$env_file"
              project_name="$BULKHEAD_PROJECT_NAME"
              # Only workspace-mcp's docker-exec target needs a name fixed
              # in advance (everything else is found by Compose via
              # project+service labels, not by a literal name) - see
              # docker-compose.yml's WORKSPACE_CONTAINER_NAME/
              # WORKSPACE_CONTAINER_ID comments. For the default profile
              # this is exactly "bulkhead-workspace", matching what was
              # hardcoded before this change.
              export WORKSPACE_CONTAINER_NAME="$BULKHEAD_WORKSPACE_CONTAINER_NAME"
              # The one image tag that's allowed to differ per profile - see
              # scripts/lib/profile.sh's own comment for why the other five
              # images aren't namespaced this way.
              export WORKSPACE_IMAGE="$BULKHEAD_WORKSPACE_IMAGE"

              # Every docker-compose call from here on goes through this, so
              # Compose's own ''${VAR} interpolation always resolves against
              # the same file this script just sourced for its own decisions
              # (e.g. WORKSPACE_DOCKERFILE_DIR below) - a bare
              # `docker-compose up` would silently fall back to .env instead
              # whenever a profile is in use. -p pins the project name
              # explicitly rather than trusting Compose's own default (the
              # cwd's basename, which is the *same* for every profile since
              # they all run from this one checkout - collides on every
              # network/volume without this).
              dc() {
                ${pkgs.docker-compose}/bin/docker-compose -p "$project_name" --env-file "$env_file" "$@"
              }

              if [ -n "''${WORKSPACE_DOCKERFILE_DIR:-}" ]; then
                echo "== Building workspace image from WORKSPACE_DOCKERFILE_DIR=$WORKSPACE_DOCKERFILE_DIR ==" >&2
                ${pkgs.docker}/bin/docker build $no_cache -t "$WORKSPACE_IMAGE" "$WORKSPACE_DOCKERFILE_DIR"
              else
                echo "== Building workspace-image via Nix (default minimal image; set WORKSPACE_DOCKERFILE_DIR in your env file for a custom one) ==" >&2
                result_link="$(mktemp -u)"
                ${pkgs.nix}/bin/nix build .#workspace-image -o "$result_link"
                # workspace/default.nix always bakes the fixed tag
                # bulkhead-workspace:dev (kept profile-agnostic so the Nix
                # derivation itself stays pure) - retag to this profile's
                # own $WORKSPACE_IMAGE right after loading it. flock-guarded:
                # two concurrent `up` runs on this same default-image path
                # both transiently load into that one fixed intermediate tag
                # before retagging, and without the lock a badly-timed race
                # could let one profile retag the other's freshly-loaded
                # content under its own name.
                (
                  ${pkgs.util-linux}/bin/flock 9
                  ${pkgs.docker}/bin/docker load < "$result_link"
                  ${pkgs.docker}/bin/docker tag bulkhead-workspace:dev "$WORKSPACE_IMAGE"
                ) 9>/tmp/bulkhead-workspace-image-load.lock
                rm -f "$result_link"
              fi

              echo "== Building workspace-mcp, chat-mcp, orchestrator, memory-mcp, git-mcp images via Docker ==" >&2
              ${pkgs.docker}/bin/docker build $no_cache -t bulkhead-workspace-mcp:dev workspace-mcp
              ${pkgs.docker}/bin/docker build $no_cache -t bulkhead-chat-mcp:dev chat-mcp
              ${pkgs.docker}/bin/docker build $no_cache -t bulkhead-orchestrator:dev orchestrator
              ${pkgs.docker}/bin/docker build $no_cache -t bulkhead-memory-mcp:dev memory-mcp
              ${pkgs.docker}/bin/docker build $no_cache -t bulkhead-git-mcp:dev git-mcp

              echo "== Starting docker compose (detached) ==" >&2
              dc up -d

              # git-mcp-unlock self-skips when there's nothing to unlock
              # (unconfigured / already cloned / passphrase-less key), so
              # it's safe to always call it here rather than making that a
              # manual step - only a real passphrase-protected key ever
              # actually prompts. Poll briefly first since `up -d` returns
              # as soon as containers start, not once git-mcp's own ssh-agent
              # has finished coming up (see state.py's _start_agent).
              echo "== Checking whether git-mcp's deploy key needs a passphrase ==" >&2
              attempt=0
              while ! dc exec -T git-mcp \
                  test -S /tmp/git-mcp-agent.sock >/dev/null 2>&1; do
                attempt=$((attempt + 1))
                if [ "$attempt" -ge 20 ]; then
                  echo "git-mcp not ready yet - run 'nix run .#git-unlock -- $env_file' manually once it is" >&2
                  break
                fi
                sleep 0.5
              done
              # Real pty here (no -T) so git-mcp-unlock's `stty -echo` prompt
              # works; a failed/declined/unnecessary unlock shouldn't fail
              # `up` itself, hence the `|| true`.
              dc exec git-mcp git-mcp-unlock || true

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
                chat_line="$(dc logs chat-mcp 2>/dev/null \
                  | grep -o 'chat UI: http://[^[:space:]]*' | tail -n1 || true)"
                [ -n "$chat_line" ] && break
                attempt=$((attempt + 1))
                if [ "$attempt" -ge 20 ]; then
                  echo "chat-mcp hasn't printed its URL yet - check 'docker compose logs chat-mcp'" >&2
                  break
                fi
                sleep 0.5
              done

              echo "== Stack is up (project: $project_name, env file: $env_file)." >&2
              echo "   'docker compose -p $project_name --env-file $env_file logs -f <service>' to tail logs;" >&2
              [ -n "$chat_line" ] && echo "   $chat_line" >&2
              echo "   're-run nix run .#git-unlock -- $env_file' any time (e.g. after a git-mcp restart);" >&2
              echo "   'nix run .#down -- $env_file' to stop it. ==" >&2
            '');
          };

          # `up` now runs detached (see above), so there's no foreground
          # process left to Ctrl+C - this is the counterpart to bring it down.
          # Usage: nix run .#down -- [env-file]  (defaults to .env - pass the
          # *same* profile you brought it up with, e.g. ./rust-build.conf -
          # the project-name derivation below has to match `up`'s exactly or
          # this targets the wrong stack, e.g. tears down the default one
          # instead of the profile's.)
          down = {
            type = "app";
            program = toString (pkgs.writeShellScript "bulkhead-down" ''
              set -euo pipefail
              if [ ! -f flake.nix ] || [ ! -f docker-compose.yml ]; then
                echo "run this from the bulkhead repo root (flake.nix/docker-compose.yml not found in $PWD)" >&2
                exit 1
              fi
              env_file="''${1:-.env}"
              . scripts/lib/profile.sh
              bulkhead_resolve_profile "$env_file" || exit 1
              project_name="$BULKHEAD_PROJECT_NAME"
              exec ${pkgs.docker-compose}/bin/docker-compose -p "$project_name" --env-file "$env_file" down
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
          # Usage: nix run .#git-unlock -- [env-file]  (defaults to .env -
          # must be the *same* profile the target stack was brought up
          # with, same reasoning as `down` above - this addresses git-mcp
          # by project+service, and the project name has to match.)
          git-unlock = {
            type = "app";
            program = toString (pkgs.writeShellScript "bulkhead-git-unlock" ''
              set -euo pipefail
              if [ ! -f flake.nix ] || [ ! -f docker-compose.yml ]; then
                echo "run this from the bulkhead repo root (flake.nix/docker-compose.yml not found in $PWD)" >&2
                exit 1
              fi
              env_file="''${1:-.env}"
              . scripts/lib/profile.sh
              bulkhead_resolve_profile "$env_file" || exit 1
              project_name="$BULKHEAD_PROJECT_NAME"
              exec ${pkgs.docker-compose}/bin/docker-compose -p "$project_name" --env-file "$env_file" exec git-mcp git-mcp-unlock
            '');
          };

          # Recreates the workspace container fresh from its current image -
          # undoes anything the agent changed inside it (installed packages,
          # /tmp files, etc.) without touching its /repo volume.
          # Usage: nix run .#reset-workspace -- [env-file]  (same profile
          # convention as down/git-unlock.)
          reset-workspace = {
            type = "app";
            program = toString (pkgs.writeShellScript "bulkhead-reset-workspace" ''
              set -euo pipefail
              if [ ! -f flake.nix ] || [ ! -f docker-compose.yml ]; then
                echo "run this from the bulkhead repo root (flake.nix/docker-compose.yml not found in $PWD)" >&2
                exit 1
              fi
              env_file="''${1:-.env}"
              . scripts/lib/profile.sh
              bulkhead_resolve_profile "$env_file" || exit 1
              project_name="$BULKHEAD_PROJECT_NAME"
              echo "== Recreating workspace (project: $project_name) - /repo is untouched ==" >&2
              exec ${pkgs.docker-compose}/bin/docker-compose -p "$project_name" --env-file "$env_file" up -d --force-recreate workspace
            '');
          };

          # Wipes both the workspace's working tree and git-mcp's gateway
          # mirror (docs/adr/0004-git-mcp-bundle-relay.md - the two are
          # separate volumes now, not one shared one) so both re-clone from
          # the remote from scratch - destroys any uncommitted/unpushed
          # local work. Usage: nix run .#reset-repo -- [env-file] [--yes]
          # (--yes skips the confirmation prompt, for scripted use.)
          reset-repo = {
            type = "app";
            program = toString (pkgs.writeShellScript "bulkhead-reset-repo" ''
              set -euo pipefail
              if [ ! -f flake.nix ] || [ ! -f docker-compose.yml ]; then
                echo "run this from the bulkhead repo root (flake.nix/docker-compose.yml not found in $PWD)" >&2
                exit 1
              fi
              yes=""
              env_file=".env"
              for arg in "$@"; do
                case "$arg" in
                  --yes) yes="1" ;;
                  *) env_file="$arg" ;;
                esac
              done
              . scripts/lib/profile.sh
              bulkhead_resolve_profile "$env_file" || exit 1
              project_name="$BULKHEAD_PROJECT_NAME"
              repo_volume="''${project_name}_workspace-repo"
              gateway_volume="''${project_name}_git-gateway-data"

              if [ -z "$yes" ]; then
                printf 'This destroys the "%s" and "%s" volumes (any uncommitted/unpushed work in /repo, and git-mcp'"'"'s gateway mirror) and re-clones both from the remote. Type "yes" to continue: ' "$repo_volume" "$gateway_volume" >&2
                read -r confirm
                [ "$confirm" = "yes" ] || { echo "aborted" >&2; exit 1; }
              fi

              dc() { ${pkgs.docker-compose}/bin/docker-compose -p "$project_name" --env-file "$env_file" "$@"; }
              echo "== Stopping workspace/git-mcp, wiping $repo_volume and $gateway_volume, recreating fresh ==" >&2
              dc stop workspace git-mcp
              ${pkgs.docker}/bin/docker volume rm "$repo_volume" "$gateway_volume"
              dc up -d --force-recreate workspace git-mcp
            '');
          };
        };

        devShells.default = pkgs.mkShell {
          packages = [ pkgs.docker pkgs.docker-compose pkgs.python3 ];
        };
      });
}
