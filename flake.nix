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
            # Same label the `up` app's builds carry - see its own comment -
            # so `nix run .#prune-images` finds this one too.
            exec ${pkgs.docker}/bin/docker build $no_cache --label bulkhead=1 -t ${tag} ${dir}
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

              # WORKSPACE_USER (docker-compose.yml's `user:` on the
              # workspace service) only matters with WORKSPACE_HOST_PATH set
              # - a bind-mounted host directory keeps its host-side
              # ownership, which workspace's baked-in UID (10001, see
              # workspace/default.nix) generally won't have write access to.
              # Auto-default to the invoking user's own uid:gid in that case
              # unless the env file already set WORKSPACE_USER explicitly -
              # covers the common case (bind-mounting your own checkout)
              # with no config needed.
              if [ -n "''${WORKSPACE_HOST_PATH:-}" ] && [ -z "''${WORKSPACE_USER:-}" ]; then
                export WORKSPACE_USER="$(id -u):$(id -g)"
                echo "== WORKSPACE_HOST_PATH set, no WORKSPACE_USER given - defaulting workspace's container user to $WORKSPACE_USER (yours) ==" >&2
              fi

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

              # BuildKit for every docker build below - required for
              # --secret (WORKSPACE_BUILD_SECRET_HOST_PATH just below), and
              # a strict improvement over the legacy builder either way for
              # the plain Dockerfiles here (no BuildKit-only syntax used, so
              # no behavior change for the five control-plane images).
              export DOCKER_BUILDKIT=1
              # Every image this script builds gets this label, purely so
              # `nix run .#prune-images` can find and remove the dangling
              # (superseded, untagged) layers repeated rebuilds leave behind
              # without touching images from unrelated projects on the same
              # Docker daemon. Not applied to the Nix-built default
              # workspace image path below (docker load/tag has no --label
              # equivalent; that path doesn't carry large vendored-dependency
              # layers the way a custom WORKSPACE_DOCKERFILE_DIR can, so it's
              # a smaller gap).
              bulkhead_label="--label bulkhead=1"

              if [ -n "''${WORKSPACE_DOCKERFILE_DIR:-}" ]; then
                echo "== Building workspace image from WORKSPACE_DOCKERFILE_DIR=$WORKSPACE_DOCKERFILE_DIR ==" >&2
                # WORKSPACE_BUILD_SECRET_HOST_PATH (optional) - a file on the
                # host holding a build-time-only credential (e.g. a GitHub
                # PAT for a private git dependency fetched during the build,
                # such as `west update`) - see README's "Custom workspace
                # image" section for the Dockerfile-side RUN --mount=type=secret
                # pattern that consumes it. Passed via BuildKit's --secret,
                # not --build-arg or a file copied into the build context:
                # --secret is mounted only for the one RUN instruction that
                # declares it and is never written to any image layer or
                # left in `docker history`, so the token never reaches the
                # image, the container filesystem, or anything at runtime.
                secret_args=""
                if [ -n "''${WORKSPACE_BUILD_SECRET_HOST_PATH:-}" ]; then
                  secret_id="''${WORKSPACE_BUILD_SECRET_ID:-workspace_build_token}"
                  secret_args="--secret id=$secret_id,src=$WORKSPACE_BUILD_SECRET_HOST_PATH"
                fi
                ${pkgs.docker}/bin/docker build $no_cache $bulkhead_label $secret_args -t "$WORKSPACE_IMAGE" "$WORKSPACE_DOCKERFILE_DIR"
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
              ${pkgs.docker}/bin/docker build $no_cache $bulkhead_label -t bulkhead-workspace-mcp:dev workspace-mcp
              ${pkgs.docker}/bin/docker build $no_cache $bulkhead_label -t bulkhead-chat-mcp:dev chat-mcp
              ${pkgs.docker}/bin/docker build $no_cache $bulkhead_label -t bulkhead-orchestrator:dev orchestrator
              ${pkgs.docker}/bin/docker build $no_cache $bulkhead_label -t bulkhead-memory-mcp:dev memory-mcp
              ${pkgs.docker}/bin/docker build $no_cache $bulkhead_label -t bulkhead-git-mcp:dev git-mcp

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
              if [ ! -f "$env_file" ]; then
                echo "env file '$env_file' not found" >&2
                exit 1
              fi
              # Same WORKSPACE_USER auto-default as `up` (see its own
              # comment above) - needed here too, or a container recreated
              # via this command silently loses the auto-detected uid:gid
              # and falls back to the image's own baked-in user.
              set -a
              . "$env_file"
              set +a
              if [ -n "''${WORKSPACE_HOST_PATH:-}" ] && [ -z "''${WORKSPACE_USER:-}" ]; then
                export WORKSPACE_USER="$(id -u):$(id -g)"
              fi
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
              if [ ! -f "$env_file" ]; then
                echo "env file '$env_file' not found" >&2
                exit 1
              fi
              # Needed for WORKSPACE_HOST_PATH below - profile.sh alone only
              # derives names, it doesn't load the file's own values (see
              # the `up` app above for the same pattern).
              set -a
              . "$env_file"
              set +a
              . scripts/lib/profile.sh
              bulkhead_resolve_profile "$env_file" || exit 1
              project_name="$BULKHEAD_PROJECT_NAME"
              gateway_volume="''${project_name}_git-gateway-data"
              dc() { ${pkgs.docker-compose}/bin/docker-compose -p "$project_name" --env-file "$env_file" "$@"; }

              # WORKSPACE_HOST_PATH (docker-compose.yml) makes the working
              # tree a host bind mount instead of the workspace-repo named
              # volume - there's nothing Docker-managed to wipe there, and
              # deleting a user's own host directory is a different, far
              # scarier operation than this command is meant to do silently.
              # Only the gateway mirror gets reset in that case.
              if [ -n "''${WORKSPACE_HOST_PATH:-}" ]; then
                echo "WORKSPACE_HOST_PATH is set ($WORKSPACE_HOST_PATH) - the working tree is a host bind mount, not a volume this command can wipe. Reset/re-clone that directory yourself." >&2
                if [ -z "$yes" ]; then
                  printf 'This still destroys the "%s" volume (git-mcp'"'"'s gateway mirror) and re-clones it from the remote. Type "yes" to continue: ' "$gateway_volume" >&2
                  read -r confirm
                  [ "$confirm" = "yes" ] || { echo "aborted" >&2; exit 1; }
                fi
                echo "== Stopping git-mcp, wiping $gateway_volume, recreating fresh ==" >&2
                dc stop git-mcp
                ${pkgs.docker}/bin/docker volume rm "$gateway_volume"
                dc up -d --force-recreate git-mcp
                exit 0
              fi

              repo_volume="''${project_name}_workspace-repo"

              if [ -z "$yes" ]; then
                printf 'This destroys the "%s" and "%s" volumes (any uncommitted/unpushed work in /repo, and git-mcp'"'"'s gateway mirror) and re-clones both from the remote. Type "yes" to continue: ' "$repo_volume" "$gateway_volume" >&2
                read -r confirm
                [ "$confirm" = "yes" ] || { echo "aborted" >&2; exit 1; }
              fi

              echo "== Stopping workspace/git-mcp, wiping $repo_volume and $gateway_volume, recreating fresh ==" >&2
              dc stop workspace git-mcp
              ${pkgs.docker}/bin/docker volume rm "$repo_volume" "$gateway_volume"
              dc up -d --force-recreate workspace git-mcp
            '');
          };

          # Reclaims disk from superseded image builds - every `nix run
          # .#up`/build-*-image rebuild that changes anything retags its
          # image, leaving the previous build's now-untagged ("dangling")
          # image behind rather than cleaning it up itself. Matters most for
          # a custom WORKSPACE_DOCKERFILE_DIR that vendors a large git
          # dependency tree at build time (see README's "Custom workspace
          # image" section) - that layer can be sizeable, and a live-updated
          # or frequently-rebuilt manifest means it accumulates fast.
          #
          # No profile argument - a dangling image is by definition untagged
          # and unreferenced by any profile's current build, so this is safe
          # to run regardless of which profile(s) are up, and reclaims all
          # of them in one pass.
          #
          # Scoped by the `bulkhead=1` label every build in this flake
          # applies (not to every dangling image on the host - this
          # shouldn't touch unrelated projects' builds on the same Docker
          # daemon). Only removes the *images* themselves - the underlying
          # layers a superseded build shares with the current one (e.g. an
          # unchanged base/toolchain layer earlier in the Dockerfile) stay
          # shared and cached regardless, by ordinary Docker layer
          # deduplication - nothing here needs to know which layers those
          # are. Usage: nix run .#prune-images [--builder-cache]
          prune-images = {
            type = "app";
            program = toString (pkgs.writeShellScript "bulkhead-prune-images" ''
              set -euo pipefail
              builder_cache=""
              for arg in "$@"; do
                case "$arg" in
                  --builder-cache) builder_cache="1" ;;
                esac
              done
              echo "== Removing dangling Bulkhead-built images (label bulkhead=1) ==" >&2
              ${pkgs.docker}/bin/docker image prune -f --filter "label=bulkhead=1"
              if [ -n "$builder_cache" ]; then
                echo "== Pruning the whole Docker builder cache (--builder-cache) - NOT scoped to Bulkhead: this reclaims build cache for every project using this Docker daemon, not just this one. Only pass this if you actually want that. ==" >&2
                ${pkgs.docker}/bin/docker builder prune -f
              fi
            '');
          };
        };

        devShells.default = pkgs.mkShell {
          packages = [ pkgs.docker pkgs.docker-compose pkgs.python3 ];
        };
      });
}
