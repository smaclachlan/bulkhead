# Bulkhead - Sandbox Environment for keeping your Agents in the box.

Bulkhead is the strong, secure, load-bearing core that keeps your AI agents
moving - a fixed, trusted hub that lets disposable workspace containers
rotate on and off around it, without ever letting the agent itself bear
the weight of host access it shouldn't have.

# Outline
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

# Egress
Point 4 covers commands going into the Workspace Sandbox. Getting data back out needs to be just as strict, and will use two controlled paths:
1) Git MCP - handles code egress. Local git work (commit, branch, diff, log) isn't gated - the Workspace Sandbox is already fully network isolated (point 4) so a local git binary in there can't reach a remote anyway, and the Workspace doesn't even need git installed since the MCP can do this local work on the Agent's behalf too. The MCP itself only has limited powers for the one action that actually crosses the boundary: push to a pre-configured remote and branch pattern, no arbitrary remotes, no force-push, no git config changes, no hooks. Holds the auth credentials itself so the Workspace Sandbox/Agent never see them, and requires human approval before an external push goes out.
2) Build artifacts - egressed via a host triggered "docker cp", run from the same privileged MCP host container that owns the Docker socket (point 4), rather than anything inside the Workspace Sandbox. Only allowed to copy from a pre-declared output directory in the workspace, never an arbitrary path. Still to decide if artifacts get scanned/size-capped on the way out too.



# Threat Model
Key things this is trying to stop:
1) Uncontrolled data egress - the Agent or a compromised MCP server getting data (code, secrets, internal info) out of the Workspace Sandbox by anything other than the two approved paths in Egress above.
2) Commands escaping the Workspace Sandbox - the Agent (or something it's tricked into running) reaching the host or other containers, rather than staying confined to what's passed through the docker exec API in point 4.
3) The Agent accessing external services maliciously - using its internet access (point 1) or search/MCP tools to hit disallowed endpoints, exfiltrate via a search/tool call, or get manipulated by malicious/injected content it fetches.

Not really in scope right now: protecting the Agent/harness from a malicious user who already has full control of the Orchestrator - this is about containing the Agent, not the operator.

# Further Threats to Consider
Not building for these in v1, but keeping them in mind now in case they change the shape of the project:
1) Confused deputy via approved channels - prompt injection tricking the Agent into misusing the Git MCP or artifact egress to push/exfiltrate something bad through a legitimate path. This cuts both ways on bidirectional channels (e.g. a Slack MCP): the same tool that lets external content reach the Agent as commands can double as an exfiltration path if its outbound side accepts freeform text. Mitigated by the Git MCP requiring human approval before an external push (see Egress above), and by holding every MCP's outbound side to the narrowest-vocabulary principle (see cornerstone 9) so injected instructions have no freeform field to exfiltrate through; artifact egress still needs the human-approval treatment.
2) MCP server / supply chain compromise - a "vetted" MCP server being malicious or compromised after the fact. Mitigate with pinned/signed MCP server builds and least-privilege scoping per MCP so a compromised one has a small blast radius.
3) Orchestrator compromise - already mitigated by design, as the Orchestrator sits in its own MicroVM with no Bash/CLI access (point 1); residual risk is a logic bug in the Harness itself abusing its allowed MCP calls, which point 3's strict marshalling should catch.
4) Resource exhaustion / cost - a runaway Agent loop hammering paid APIs or filling disk. Mitigate with rate limits/quotas enforced at the MCP/Orchestrator boundary.
5) Cross-session/cross-agent leakage - state or data leaking between reused Workspace containers in a multi-agent setup. Mitigate by treating Workspace containers as ephemeral and destroying/recreating them per session.
6) Memory-store poisoning (phase 2, docs/adr/0002-phase-2-isolation-ux-memory.md Decision 4) - content the Agent reads via workspace_exec (a file, a command's output) could carry injected text instructing it to persist something into the Memory MCP server that then gets trusted in a *later* session, since that store is deliberately meant to survive across sessions. Not solved in phase 2; candidate mitigation is surfacing what's about to be persisted to the human before it's written, in a later phase.

# Caveats:
- Many MCP servers will increase context use slightly
- The Workspace container if mapped directly to host maybe a security risk, although potentially easier to use.

Notes:
- Podman currently doesn't seem a viable platform for MicroVM's at this point (Sept 2026), Podman Machine can be setup to do a similar job, but is much more manual, has some defaults that are incompatible etc.  Also trying to reduce the surface of implementation at this point.  Never say never.

## Kata Containers setup (phase 2, Workspace container)

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

### Validating it end-to-end

- `docker info | grep -A5 Runtimes` should list `kata` alongside `runc`.
- `docker inspect bulkhead-workspace --format '{{.HostConfig.Runtime}}'` → `kata`.
- With `WORKSPACE_RUNTIME=kata` set in the environment, `sh scripts/validate-phase2.sh` runs its step 8 Kata check automatically instead of skipping it (see `docs/plans/phase-2-validation.md`).
- The same kernel-differential check `setup-kata-host.sh` ran against a bare `docker run`, but *through Bulkhead* this time: ask the agent in chat to run `uname -r` (it'll go through `workspace_exec`) and compare against the host's own `uname -r`.

## Git MCP setup (phase 3, code egress)

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
`git_branch_list`/`git_commit`/`git_create_branch`/`git_checkout` available
immediately (all local, all ungated) plus `git_push_request(branch)`, which
only *stages* a push - it never pushes on its own. A pending push shows up
in chat as e.g.:

```
Pending push approval:
- 3f9a1c2b8e0d4a5f: push HEAD -> origin/agent/my-branch (reply 'approve 3f9a1c2b8e0d4a5f' or 'deny 3f9a1c2b8e0d4a5f')
```

Replying `approve <id>` or `deny <id>` is handled by the Orchestrator's
harness code directly - not the LLM - and is the only way an external push
actually goes out (README's Egress section / ADR-0003 Decision 3).
