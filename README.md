# Pandora - Sandbox Environment for keeping your Agents in the box.

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
1) Confused deputy via approved channels - prompt injection tricking the Agent into misusing the Git MCP or artifact egress to push/exfiltrate something bad through a legitimate path. Mitigated by the Git MCP requiring human approval before an external push (see Egress above); artifact egress still needs the same treatment.
2) MCP server / supply chain compromise - a "vetted" MCP server being malicious or compromised after the fact. Mitigate with pinned/signed MCP server builds and least-privilege scoping per MCP so a compromised one has a small blast radius.
3) Orchestrator compromise - already mitigated by design, as the Orchestrator sits in its own MicroVM with no Bash/CLI access (point 1); residual risk is a logic bug in the Harness itself abusing its allowed MCP calls, which point 3's strict marshalling should catch.
4) Resource exhaustion / cost - a runaway Agent loop hammering paid APIs or filling disk. Mitigate with rate limits/quotas enforced at the MCP/Orchestrator boundary.
5) Cross-session/cross-agent leakage - state or data leaking between reused Workspace containers in a multi-agent setup. Mitigate by treating Workspace containers as ephemeral and destroying/recreating them per session.

# Caveats:
- Many MCP servers will increase context use slightly
- The Workspace container if mapped directly to host maybe a security risk, although potentially easier to use.

Notes:
- Podman currently doesn't seem a viable platform for MicroVM's at this point (Sept 2026), Podman Machine can be setup to do a similar job, but is much more manual, has some defaults that are incompatible etc.  Also trying to reduce the surface of implementation at this point.  Never say never.
