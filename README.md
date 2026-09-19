# Bulkhead - Sandbox Environment for keeping your Agents in the box.

Bulkhead is the strong, secure, load-bearing core that keeps your AI agents
moving - a fixed, trusted hub that lets disposable workspace containers
rotate on and off around it, without ever letting the agent itself bear
the weight of host access it shouldn't have.

## Contents

- [Quick start](#quick-start)
- [Usage guide](#usage-guide)
  - [Configuration (`.env`)](#configuration-env)
  - [Custom workspace image](#custom-workspace-image)
  - [Resetting the workspace](#resetting-the-workspace)
  - [Profiles - running multiple concurrent stacks](#profiles---running-multiple-concurrent-stacks)
  - [Git MCP setup (phase 3, code egress)](#git-mcp-setup-phase-3-code-egress)
  - [Kata Containers setup (phase 2, Workspace container)](#kata-containers-setup-phase-2-workspace-container)
  - [Validating your setup](#validating-your-setup)
- [Architecture & Design](#architecture--design)
  - [Design principles](#design-principles)
  - [Egress](#egress)
  - [Threat Model](#threat-model)
  - [Further Threats to Consider](#further-threats-to-consider)
  - [Docker socket proxy](#docker-socket-proxy)
- [Caveats & Notes](#caveats--notes)

## Quick start

**Prerequisites:**
- [Nix](https://nixos.org/download) with flakes enabled (`nix --version` recent enough for `nix run .#<app>` - if flakes aren't already on, add `experimental-features = nix-command flakes` to your Nix config).
- Docker (or a Docker-compatible daemon) installed *and running* - `docker info` should succeed, not error. Nix provides the `docker`/`docker compose` CLI binaries the flake's apps use; it does not provide or manage the daemon itself.

**Get running**, from the repo root:

```
cp .env.example .env
# edit .env - at minimum, set ANTHROPIC_API_KEY
nix run .#up
```

This builds every container image (the Workspace image via Nix, everything else via `docker build`) and brings the stack up detached. It prints the Chat UI's URL (with its access token) once `chat-mcp` is ready, and re-runs `git-mcp-unlock` automatically if a passphrase-protected deploy key needs unlocking.

**What's running** (see [Architecture & Design](#architecture--design) for why it's split this way):

| Container | Role |
|---|---|
| `workspace` | Where the agent's shell commands actually run - network-isolated, no Docker socket. |
| `workspace-mcp` | The only container with a path to Docker; exposes one narrow `exec` tool. |
| `docker-socket-proxy` | Filtered Docker socket access for `workspace-mcp` - real socket never leaves this container. |
| `memory-mcp` | Persistent, cross-session agent memory (a knowledge graph). |
| `git-mcp` | The only path code takes out of the sandbox - local git ops plus a human-gated push. |
| `chat-mcp` | The chat UI/REST API you talk to the agent through. |
| `orchestrator` | Runs the LLM/tool-calling harness that ties the above together. |

**Talk to the agent** - either open the printed Chat UI URL in a browser, or use the terminal client:

```
nix run .#chat                          # persistent live chat (REPL)
nix run .#chat -- send "hi" --wait      # one message, print the reply, exit
```

**Bring it down** when you're done:

```
nix run .#down
```

## Usage guide

### Configuration (`.env`)

Every Bulkhead setting lives in one `.env`-format file - copy `.env.example` to `.env` and fill it in. Only `ANTHROPIC_API_KEY` is required to bring the stack up at all; everything else is optional and defaults to a sane, unconfigured value:

- `ANTHROPIC_API_KEY` - required; the Orchestrator's LLM calls.
- `CHAT_MCP_TOKEN` - pin the Chat UI's access token instead of a fresh random one per boot (either way it's printed by `nix run .#up` / visible in `docker compose logs chat-mcp`).
- `CHAT_SHOW_TOOL_CALLS` - off by default, so the chat transcript only shows the agent's actual replies. Set to `1`/`true`/`yes` to keep the underlying `[Calling tool X with args Y]` notices mcp-agent bakes into its output - both the browser UI and `nix run .#chat` render those lines in italics so they're still visually distinct from the real reply.
- `WORKSPACE_RUNTIME`, `WORKSPACE_DOCKERFILE_DIR`, `WORKSPACE_REPO_PATH` - see [Custom workspace image](#custom-workspace-image) and [Kata Containers setup](#kata-containers-setup-phase-2-workspace-container).
- `CHAT_UI_HOST_PORT` - see [Profiles](#profiles---running-multiple-concurrent-stacks).
- `GIT_REMOTE_URL`, `GIT_SSH_DEPLOY_KEY_HOST_PATH`, `GIT_PUSH_BRANCH_PATTERN` - see [Git MCP setup](#git-mcp-setup-phase-3-code-egress).

`.env` is already gitignored - never commit it or the values inside it.

### Custom workspace image

The default Workspace image (`workspace/default.nix`) is deliberately minimal - coreutils and a shell, nothing else (ADR-0001 §3: a phase-1 simplicity choice, not a security one). Cornerstone 7 always wanted more than that: "any OCI container... with the full build environment for the user's tooling setup." Two `.env` values get you there:

- `WORKSPACE_DOCKERFILE_DIR` - a directory containing your own Dockerfile. When set, `nix run .#up` builds it as the Workspace image instead of the Nix one. Whatever that image's own `CMD`/`ENTRYPOINT` is, it never runs - `docker-compose.yml` overrides the container's command to just idle (`sh -c "sleep infinity"`), since `workspace-mcp` only ever `docker exec`s into it, never `docker run`s per command. This means the image needs a POSIX shell and `sleep` present; essentially any real base distro has both.
- `WORKSPACE_REPO_PATH` - where the shared working tree (the volume `git-mcp` clones/commits/pushes on the agent's behalf) is mounted inside both `git-mcp` and `workspace`. Defaults to `/repo`; override it if your Dockerfile's tooling expects the project root somewhere else. All three of the mount point, `git-mcp`'s own `GIT_REPO_PATH`, and `workspace`'s mount target read this one value, so they can't drift apart.

One thing this doesn't solve for you: if your custom image runs as a non-root user, check that user can actually read/write the shared volume - `git-mcp` writes to it as its own container's (root) user, and a UID mismatch will surface as confusing permission errors in your build tooling rather than an obvious "wrong config" message.

### Resetting the workspace

Two commands, two different amounts of destruction:

```
nix run .#reset-workspace -- [env-file]    # fresh container, /repo untouched
nix run .#reset-repo -- [env-file] [--yes] # also wipes /repo - asks to confirm
```

`reset-workspace` recreates the `workspace` container from its current image - undoes anything the agent changed inside the container itself (installed packages, `/tmp` files, etc.) without touching the shared working tree. `reset-repo` goes further: it also deletes the `workspace-repo` volume so `git-mcp` re-clones from the remote on next start - this destroys any uncommitted or unpushed local work, so it asks for a typed `yes` first (`--yes` skips that, for scripted use). Both take the same optional profile path as `down`/`git-unlock`.

### Profiles - running multiple concurrent stacks

Every Bulkhead config value lives in one `.env`-format file, so a second project's setup is just a second file in that same format (any name/extension - `./rust-build.conf`, `./profiles/python.env`, whatever):

```
nix run .#up -- ./rust-build.conf     # bring up (or switch to) that profile
nix run .#git-unlock -- ./rust-build.conf
nix run .#down -- ./rust-build.conf
```

(Note the `--` before the file path - required for `nix run` to pass it through rather than trying to parse it itself, same as `nix run .#chat -- send "hi"` above.)

Omitting the path uses `.env` and the project name `bulkhead`, unchanged from before profiles existed. Any other file gets its project name from its own basename (`rust-build.conf` → `rust-build`), which Compose uses to namespace that stack's containers/networks/volumes separately from any other profile's - so **multiple profiles can run concurrently**, each fully isolated, not just switched between. Two things to set per additional concurrent profile so they don't collide on host-level resources (namespacing handles everything else automatically):

- `CHAT_UI_HOST_PORT` - each concurrent stack's Chat UI needs its own host port (default `8787`).
- Nothing else needs a manual value - `WORKSPACE_CONTAINER_NAME` (what `workspace-mcp` targets via `docker exec`) and the Workspace image's own tag are both derived automatically from the profile, not something to set by hand. The Workspace image is the one image namespaced per profile (`bulkhead-workspace:dev` for the default profile, `bulkhead-workspace:<project>` otherwise) - it's the one whose content is meant to vary per profile (a custom `WORKSPACE_DOCKERFILE_DIR` is the whole point of a second profile). The other five images (`workspace-mcp`, `chat-mcp`, `orchestrator`, `memory-mcp`, `git-mcp`) are Bulkhead's own control-plane code, always built from this one checkout regardless of profile, so every profile shares those five tags - that's correct, not a collision.

`nix run .#down`/`nix run .#git-unlock` must be given the *same* profile path used to bring that stack up - they derive the identical project name from it to find the right one; passing the wrong path (or none, meaning `.env`) targets a different stack, not an error. `scripts/validate-phase2.sh`/`validate-phase3.sh`/`scripts/check-mcp-allowlist.sh` take the same optional profile-path argument (e.g. `sh scripts/validate-phase2.sh ./rust-build.conf`), and `nix run .#chat -- --env-file ./rust-build.conf send "hi" --wait` targets that profile's chat stack instead of the default one's.

Two things concurrent profiles don't (yet) get their own isolation for:

- **`docker-socket-proxy`'s access control is category-only** (see [Docker socket proxy](#docker-socket-proxy) below) - it can't restrict *which* container `EXEC` targets. Under one profile that means a compromised `workspace-mcp` could exec into any container on the host; running profiles concurrently widens that to any container across *every* running profile's stack, since they all share the one real host `/var/run/docker.sock` this proxy fronts. This is a pre-existing, already-tracked gap (see ADR-0002's follow-ups), not something concurrent profiles introduce or that this feature attempts to fix.
- **`GIT_SSH_DEPLOY_KEY_HOST_PATH`**, left unset, defaults to the same placeholder file for every profile (harmless - it's a read-only bind mount of a non-key placeholder) - set a distinct path per profile if you want each to use its own real deploy key.

### Git MCP setup (phase 3, code egress)

See [ADR-0003](docs/adr/0003-phase-3-git-mcp.md) for the full design. Three
`.env` values are required before `git-mcp` will start - see
`.env.example`:

```
GIT_REMOTE_URL=git@github.com:your-org/your-repo.git
GIT_SSH_DEPLOY_KEY_HOST_PATH=/path/to/a/deploy_key
GIT_PUSH_BRANCH_PATTERN=agent/*   # default shown; the agent can only push here
```

The deploy key should be scoped to that one repo on the remote host (a
GitHub/GitLab "deploy key", not a personal SSH key) - it's bind-mounted
read-only into `git-mcp` alone and never reaches any other container.

Once the stack is up, the agent has `git_status`/`git_diff`/`git_log`/
`git_branch_list`/`git_commit`/`git_create_branch`/`git_checkout`/
`git_show`/`git_remote`/`git_rev_parse`/`git_merge_base`/`git_tag_list`
available immediately (all local, all ungated) and `git_fetch` too (the one
other tool here that reaches the network - read-direction only, against the
one pre-configured remote, never pushes), plus `git_push_request(branch)`,
which only *stages* a push - it never pushes on its own. A pending push
shows up in chat as e.g.:

```
Pending push approval:
- 3f9a1c2b8e0d4a5f: push HEAD -> origin/agent/my-branch (reply 'approve 3f9a1c2b8e0d4a5f' or 'deny 3f9a1c2b8e0d4a5f')
```

Replying `approve <id>` or `deny <id>` is handled by the Orchestrator's
harness code directly - not the LLM - and is the only way an external push
actually goes out ([Egress](#egress) / ADR-0003 Decision 3).

### Kata Containers setup (phase 2, Workspace container)

See [ADR-0002 Decision 1](docs/adr/0002-phase-2-isolation-ux-memory.md#decision) - `docker-compose.yml`'s `workspace` service takes its OCI runtime from `WORKSPACE_RUNTIME` (default `runc`, so an unmodified checkout still works without Kata installed).

**Not via Nix.** `nixpkgs` only has `pkgs.kata-runtime` (the `containerd-shim-kata-v2` binary) - it doesn't package the guest kernel/rootfs image Kata also needs to boot a microVM, and on a non-NixOS host Nix doesn't manage `/etc/docker/daemon.json` either way. There's also no `apt` package for it (checked both Debian and Ubuntu).

**`scripts/setup-kata-host.sh`** does this instead - Debian/Ubuntu only. Idempotent (safe to re-run; skips anything already done):

```
sh scripts/setup-kata-host.sh
```

It installs Docker (`docker.io` + the compose plugin) if missing, downloads and extracts Kata's pre-built release under `/opt/kata`, registers it in `/etc/docker/daemon.json` (merging in just the `kata` runtime entry - it won't touch anything else already in that file), and finishes by running `docker run --runtime kata --rm ubuntu:24.04 uname -r` to confirm the guest kernel actually differs from the host's. The registration Kata's own docs specify for Docker is a direct path to the shim binary plus its QEMU config, not a bare runtime-type name:
```json
{
  "runtimes": {
    "kata": {
      "runtimeType": "/opt/kata/runtime-rs/bin/containerd-shim-kata-v2",
      "options": { "ConfigPath": "/opt/kata/share/defaults/kata-containers/runtime-rs/configuration-qemu-runtime-rs.toml" }
    }
  }
}
```

Once that script passes, set `WORKSPACE_RUNTIME=kata` in `.env` and re-run `nix run .#up`.

If Bulkhead itself runs inside a VM (a cloud dev box, CI), nested virtualization needs to be enabled on that host first - Kata needs real KVM access, not just a registered runtime name.

**Validating it end-to-end:**

- `docker info | grep -A5 Runtimes` should list `kata` alongside `runc`.
- `docker inspect bulkhead-workspace --format '{{.HostConfig.Runtime}}'` → `kata`.
- With `WORKSPACE_RUNTIME=kata` set in the environment, `sh scripts/validate-phase2.sh` runs its step 8 Kata checks automatically instead of skipping them (see `docs/plans/phase-2-validation.md`) - both that the runtime label says `kata` *and* that a real `containerd-shim-kata-v2` process backs the container, since the label alone only proves Docker was told to use Kata, not that a shim/VMM actually came up for it.
- The same kernel-differential check `setup-kata-host.sh` ran against a bare `docker run`, but *through Bulkhead* this time: ask the agent in chat to run `uname -r` (it'll go through `workspace_exec`) and compare against the host's own `uname -r`. This is the one fully conclusive check - the two automated ones above can still both look right on a config-only regression.

### Validating your setup

Each completed phase has an automated harness that drives the real chat/LLM path and records a timestamped attestation, not just a one-off terminal pass/fail - see `validation-results/README.md` for the record format and `docs/plans/phase-*-validation.md` for what each step checks and why. Run these with the stack up:

```
sh scripts/validate-phase2.sh          # chat UX, network isolation, memory persistence, Kata (if opted in)
sh scripts/validate-phase3.sh          # git-mcp isolation, local git ops, push-approval flow (opt-in on GIT_REMOTE_URL)
sh scripts/check-mcp-allowlist.sh      # every MCP server exposes exactly its intended tool names, nothing more
```

All three need a valid `ANTHROPIC_API_KEY` (several steps drive real chat turns) and, like `nix run .#up`/`down`/`git-unlock`, take an optional profile env-file argument to target a non-default concurrent profile instead of assuming `.env` (e.g. `sh scripts/validate-phase2.sh ./rust-build.conf`) - see [Profiles](#profiles---running-multiple-concurrent-stacks).

## Architecture & Design

### Design principles

This is intended to be a multi platform, multi agent capable sandbox environment that is pedantic about ensuring agents can not escape their sandbox environment and run dissallowed commands on the local system, whilst still allowing them to progress with their intended task in an un-hindered way.

System will be managed by Nix (possibly flake) so that it can be used where Nix is supported and will build upon Micro VM Container sessions (Docker Sandboxes, Apple Containers) to run the different aaspects of the system. Logicial aspects of the system will be run in individual containers such as:
- Agent orchestrator
- Workspace sandbox
- MCP Access Host
- Other MCP services

The general premise is to contain each container to bare least priviledges from an outset. This will then underlayed by some fundamental cornerstone concepts:
1) The Agent Orchestrator will run in its own MicroVM container, with internet access to allow for Agent connections etc, but zero Bash/CLI access.
2) The Agent Orchestrator will have an extremly limited Harness, with nearly all tools being via an MCP, proxy or internal controlled mechanism.  I.e. Search will go through an MCP to strip passwords, internal data, strange search commands etc (possibly using a small local LLM to marshall this)
3) Agent Orchestrator utilises either an opensource or custom harness where all requests from the Agent/LLM are strictly marshalled.
4) Workspace Sandbox will be completly network isolated. Only access will be via the MCP Agent host, who's strict API will only allow commands to be passed into the "docker exec" on the Workspace Sandbox. This will obviously require localhost Docker socket access - hence this is in a separate priviledged MCP container with a very simple and strict API access which will not allow generic access to the Docker socket from anything else.
5) All other tools/access will be via strictly vetted MCP servers.
6) MCP servers should where possible reduce their output by default, to reduce verbosity to the main Agent - a mechanism for the Agent to request more should be available. This adds an extra layer of potential token reduction but gives full log access if required.
7) Workspace container can be any OCI container, and should contain the full build environment for the users tooling setup.  This allows the agent to work on the project with native commands/requests for builds etc, without needing to access build servers or anything else.  This allows the workspace to be very custom and tailored to the development need.
8) Workspace Container will either utilise:
    - Mapped in host container workspace
    - Separate workspace in the container, syncing to an external server via the Git MCP (see Egress below)
9) All MCP ingress/egress pathways should use the narrowest possible vocabulary. Prefer closed enums or fixed templates over freeform text for any tool with an external side-effect (e.g. a status-reporting tool exposing `send_status(state: enum["received","working","done","error"])` rather than `send_message(text: string)`). This is enforced at the MCP tool schema, not by prompting the model to behave - so even an injected/compromised agent has no field to smuggle arbitrary data through. Reserve freeform text for pathways that already carry a human-approval gate (e.g. Git push).

### Egress

Point 4 covers commands going into the Workspace Sandbox. Getting data back out needs to be just as strict, and will use two controlled paths:
1) Git MCP - handles code egress. Local git work (commit, branch, diff, log) isn't gated - the Workspace Sandbox is already fully network isolated (point 4) so a local git binary in there can't reach a remote anyway, and the Workspace doesn't even need git installed since the MCP can do this local work on the Agent's behalf too. The MCP itself only has limited powers for the one action that actually crosses the boundary: push to a pre-configured remote and branch pattern, no arbitrary remotes, no force-push, no git config changes, no hooks. Holds the auth credentials itself so the Workspace Sandbox/Agent never see them, and requires human approval before an external push goes out.
2) Build artifacts - egressed via a host triggered "docker cp", run from the same privileged MCP host container that owns the Docker socket (point 4), rather than anything inside the Workspace Sandbox. Only allowed to copy from a pre-declared output directory in the workspace, never an arbitrary path. Still to decide if artifacts get scanned/size-capped on the way out too.

### Threat Model

Key things this is trying to stop:
1) Uncontrolled data egress - the Agent or a compromised MCP server getting data (code, secrets, internal info) out of the Workspace Sandbox by anything other than the two approved paths in Egress above.
2) Commands escaping the Workspace Sandbox - the Agent (or something it's tricked into running) reaching the host or other containers, rather than staying confined to what's passed through the docker exec API in point 4.
3) The Agent accessing external services maliciously - using its internet access (point 1) or search/MCP tools to hit disallowed endpoints, exfiltrate via a search/tool call, or get manipulated by malicious/injected content it fetches.

Not really in scope right now: protecting the Agent/harness from a malicious user who already has full control of the Orchestrator - this is about containing the Agent, not the operator.

### Further Threats to Consider

Not building for these in v1, but keeping them in mind now in case they change the shape of the project:
1) Confused deputy via approved channels - prompt injection tricking the Agent into misusing the Git MCP or artifact egress to push/exfiltrate something bad through a legitimate path. This cuts both ways on bidirectional channels (e.g. a Slack MCP): the same tool that lets external content reach the Agent as commands can double as an exfiltration path if its outbound side accepts freeform text. Mitigated by the Git MCP requiring human approval before an external push (see Egress above), and by holding every MCP's outbound side to the narrowest-vocabulary principle (see cornerstone 9) so injected instructions have no freeform field to exfiltrate through; artifact egress still needs the human-approval treatment.
2) MCP server / supply chain compromise - a "vetted" MCP server being malicious or compromised after the fact. Mitigate with pinned/signed MCP server builds and least-privilege scoping per MCP so a compromised one has a small blast radius.
3) Orchestrator compromise - already mitigated by design, as the Orchestrator sits in its own MicroVM with no Bash/CLI access (point 1); residual risk is a logic bug in the Harness itself abusing its allowed MCP calls, which point 3's strict marshalling should catch.
4) Resource exhaustion / cost - a runaway Agent loop hammering paid APIs or filling disk. Mitigate with rate limits/quotas enforced at the MCP/Orchestrator boundary.
5) Cross-session/cross-agent leakage - state or data leaking between reused Workspace containers in a multi-agent setup. Mitigate by treating Workspace containers as ephemeral and destroying/recreating them per session.
6) Memory-store poisoning (phase 2, docs/adr/0002-phase-2-isolation-ux-memory.md Decision 4) - content the Agent reads via workspace_exec (a file, a command's output) could carry injected text instructing it to persist something into the Memory MCP server that then gets trusted in a *later* session, since that store is deliberately meant to survive across sessions. Not solved in phase 2; candidate mitigation is surfacing what's about to be persisted to the human before it's written, in a later phase.
7) Docker-socket-proxy is category-only, not container-scoped - the proxy fronting workspace-mcp's Docker access (tecnativa/docker-socket-proxy) only gates whole API categories (CONTAINERS/EXEC/POST) on or off; there's no way to restrict *which* container EXEC targets. A fully-compromised workspace-mcp could exec into any container in the topology (git-mcp, chat-mcp, memory-mcp, orchestrator, the proxy itself), not just the intended Workspace container - meaning the "even if workspace-mcp's code is fully compromised" guarantee ADR-0002 Decision 3 claims only holds for the *category* of actions (no image pulls, no new containers, no volume/network tampering), not the *target*. A custom per-container nginx filter was tried and reverted (nginx doesn't reliably relay Docker's exec/attach hijack protocol over a unix-socket upstream - see [Docker socket proxy](#docker-socket-proxy) for the full story). The two real fixes - a Docker Authorization Plugin (daemon-level, never sits in the hijacked stream's data path) or a purpose-built raw-relay filter (peek at the request line once, dumb-forward the rest) - are real, unscoped follow-up work, not done yet.

### Docker socket proxy

`docker-socket-proxy` (`tecnativa/docker-socket-proxy`) is the only container holding the real Docker socket (`/var/run/docker.sock`, bind-mounted read-only into it alone - ADR-0002 Decision 3). `workspace-mcp` never gets the raw socket; it talks to this proxy instead, over `DOCKER_HOST=tcp://docker-socket-proxy:2375` on the `internal-docker-proxy` network - a network `orchestrator` isn't on, so it can't reach the proxy directly either, only through `workspace-mcp`'s own single `exec` tool. Only `CONTAINERS` (resolve the target) and `EXEC` (run in it) are granted - everything else (`IMAGES`, `NETWORKS`, `VOLUMES`, `POST`-to-create-containers, etc.) is off by default.

The point of the split: `workspace-mcp`'s own code being narrow (one tool, one hardcoded target container) protects against the *agent* misusing the interface it's given. It does nothing against `workspace-mcp`'s own process being compromised (an RCE via a framework bug, a dependency CVE, whatever) - at that point the attacker isn't going through the tool's intended interface anymore, they're running arbitrary code as that process, and no amount of "the source code only ever passes this one container name" matters once someone else's code is what's actually running. The proxy exists specifically so that even a fully-compromised `workspace-mcp` is still stuck talking to a separate container's filtered API, rather than the raw socket itself.

**Known, accepted gap: this doesn't restrict *which* container `EXEC` targets.** `tecnativa/docker-socket-proxy`'s access control only operates at the whole-API-category level (verified against its own source) - there's no env var or config that scopes `EXEC` to one container name. A fully-compromised `workspace-mcp` could still `docker exec` into `git-mcp`, `chat-mcp`, `memory-mcp`, `orchestrator`, or the proxy itself, not just the one `workspace` container it's meant to be confined to.

A custom nginx-based replacement was built and reverted: nginx's HTTP proxy module doesn't reliably relay Docker's exec/attach hijack protocol (a raw stream after an HTTP upgrade) over a unix-socket upstream. Four standard fixes were each genuinely necessary and individually confirmed live - unprivileged nginx workers can't open the socket at all (permission denied) without running as root in that one container; the docker CLI's own `/_ping` capability check is fatal if blocked, not just tolerated; the exec/start hijack needs `proxy_http_version 1.1` plus `Upgrade`/`Connection` headers to even get a `101 Switching Protocols`; and nginx still wraps a no-`Content-Length` proxied response in chunked framing by default, which breaks Docker's raw stream even after a correct upgrade - but the four together still wasn't sufficient to get actual command output through. The two real ways to close this gap without that rabbit hole: a Docker Authorization Plugin (daemon-level - approves/denies the request without ever sitting in the hijacked stream's data path, so the relay problem above doesn't arise at all, but requires host daemon config changes, similar in kind to the Kata setup above) or a purpose-built raw-relay filter (peek at just the request line for the one ACL decision, then dumb byte-forward everything else, never trying to be a real HTTP proxy for the data itself). Both are real, separately-scoped follow-ups, not attempted here.

## Caveats & Notes

Caveats:
- Many MCP servers will increase context use slightly
- The Workspace container if mapped directly to host maybe a security risk, although potentially easier to use.

Notes:
- Podman currently doesn't seem a viable platform for MicroVM's at this point (Sept 2026), Podman Machine can be setup to do a similar job, but is much more manual, has some defaults that are incompatible etc.  Also trying to reduce the surface of implementation at this point.  Never say never.
