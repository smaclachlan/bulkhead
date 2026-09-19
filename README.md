# Pandora - Sandbox Environment for keeping your Agents in the box.

# Outline
This is intended to be a multi platform, multi agent capable sandbox environment that is pedantic about ensuring agents can not escape their sandbox environment and run dissallowed commands on the local system, whilst still allowing them to progress with their intended task in an un-hindered way. 

System will be managed by Nix (possibly flake) so that it can be used where Nix is supported and will build upon Micro VM Container sessions (Docker Sandboxes, Apple Containers) to run the different aaspects of the system. Logicial aspects of the system will be run in individual containers such as:
- Agent orchestrator
- Workspace sandbox
- MCP Access Host
- Other MCP services

The general premise is to contain each container to bare least priviledges from an outset. This will then underlayed by some fundamental cornerstone concepts:
1) The Agent Orchestrator container will have internet access to allow for Agent connections etc.
2) The Agent Orchestrator will have an extremly limited Harness, with nearly all tools being via an MCP, proxy or internal controlled mechanism.  I.e. Search will go through an MCP to strip passwords, internal data, strange search commands etc (possibly using a small local LLM to marshall this) 
3) Agent Orchestrator utilises either an opensource or custom harness where all requests from the Agent/LLM are strictly marshalled.
4) Workspace Sandbox will be completly network isolated. Only access will be via the MCP Agent host, who's strict API will only allow commands to be passed into the "docker exec" on the Workspace Sandbox. This will obviously require localhost Docker socket access - hence this is in a separate priviledged MCP container with a very simple and strict API access which will not allow generic access to the Docker socket from anything else.
5) All other tools/access will be via strictly vetted MCP servers.
6) MCP servers should where possible reduce their output by default, to reduce verbosity to the main Agent - a mechanism for the Agent to request more should be available. This adds an extra layer of potential token reduction but gives full log access if required.
7) Workspace container can be any OCI container, and should contain the full build environment for the users tooling setup.  This allows the agent to work on the project with native commands/requests for builds etc, without needing to access build servers or anything else.  This allows the workspace to be very custom and tailored to the development need.
8) Workspace Container will either utilise:
    - Mapped in host container workspace
    - Separate workspace in the container, with mapped workspace folder to a GIT MCP client - allowing for syncing to external server.



# Caveats:
- Many MCP servers will increase context use slightly
- The Workspace container if mapped directly to host maybe a security risk, although potentially easier to use.

Notes:
- Podman currently doesn't seem a viable platform for MicroVM's at this point (Sept 2026), Podman Machine can be setup to do a similar job, but is much more manual, has some defaults that are incompatible etc.  Also trying to reduce the surface of implementation at this point.  Never say never.
