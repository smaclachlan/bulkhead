# MCP Gateway / Allowlist Layer — Investigation (ADR-0002 Decision 5)

ADR-0001 §5/deferred-follow-ups named the trigger condition for this
explicitly: "once more than one downstream MCP server exists." Phase 2
(Memory MCP, [ADR-0002](../adr/0002-phase-2-isolation-ux-memory.md)
Decision 4) crosses that line. Scope here, per ADR-0002 Decision 5, is
**investigate + prototype**, not a hard requirement to ship a full gateway
before Memory MCP lands.

## What a gateway would actually buy Axle

Two distinct properties get bundled under "MCP gateway" and are worth
separating:

1. **Unified management** (fleet of MCP servers, SSO, secrets, audit UI) -
   not a Axle problem yet. Two internal-only servers (workspace-mcp,
   memory-mcp) plus chat-mcp is not fleet scale, and Axle's containment
   model already puts credentials/secrets handling at the container-env
   level, not inside a shared broker.
2. **Tool-surface allowlisting** - detecting when a downstream MCP server
   exposes a tool the Orchestrator didn't expect (a compromised/mutated
   server, a supply-chain issue per README's Further Threats item 2, or
   just a version bump that silently grew the surface). This *is* a real
   gap today: nothing currently checks that workspace-mcp still exposes
   exactly `exec`, or that memory-mcp's nine tools are the nine tools
   Decision 4 named, other than `scripts/validate-phase1.sh`'s step 7
   (workspace-mcp only, and only when that script is run by hand).

## Evaluated: ToolHive

[ToolHive](https://github.com/stacklok/toolhive) wraps each MCP server in
its own managed container (Docker/Podman locally, a Kubernetes operator for
fleets), can also proxy an existing remote streamable-http server rather
than only spawning stdio ones, and layers policy on top: network-endpoint
allowlists, SSO/IdP integration, tool filtering/semantic search, audit logs.

**Mismatch with Axle's own shape**: ToolHive wants to *own* the
container-orchestration layer for MCP servers - that's exactly what
Axle's Nix-per-image + Compose-network-segmentation approach
(ADR-0001 §§1,3,4) already does, deliberately, so that least-privilege and
network boundaries are enforced by build/compose tooling this repo
controls, not by a third-party platform's own container-wrapping. Adopting
ToolHive wholesale would mean either running Axle's MCP servers *inside*
ToolHive's container model (duplicating/fighting the existing Nix+Compose
setup) or running it purely as a proxy in front of already-Compose-managed
servers (workable, but then it's providing exactly one property Axle
needs - tool-surface filtering - at the cost of a second policy engine and
its own dependency/trust surface, which is a lot of new attack surface for
one property).

**Recommendation**: don't adopt ToolHive (or an equivalent all-in-one
gateway platform) in phase 2. The unified-management half of its value
proposition doesn't match Axle's current scale or its Nix/Compose-first
philosophy, and pulling in a full gateway just for tool-surface allowlisting
is disproportionate. Revisit if/when Axle's own MCP-server count or
multi-tenant story (explicitly out of scope for phase 2 - see
phase-2-scope.md) grows enough that unified management starts paying for
itself.

## Prototype shipped in phase 2: a narrow allowlist checker

Rather than a full request-path proxy (which would need to speak the
streamable-http/session protocol correctly for every tool call - real
scope, and not something to bolt on without dedicated testing against a
live stack), phase 2 ships the narrower, directly useful half: a static
allowlist of expected tool names per downstream MCP server, and a checker
script (`scripts/check-mcp-allowlist.py`) that connects to each one
directly (same direct-MCP-client pattern as
`scripts/validate-phase1.sh` step 7) and fails loudly if the live tool list
doesn't match exactly.

This is deliberately a **detection** tool, not an enforcement gateway: it
answers "did workspace-mcp or memory-mcp's tool surface change since this
allowlist was written" as a checked-in CI/validation step
(`docs/plans/phase-2-validation.md` runs it), not a runtime request filter
sitting in the Orchestrator's path. Promoting it to a real inline proxy -
rejecting a live tool call that isn't on the allowlist, not just reporting
drift after the fact - is the natural next step if this phase 2 prototype
proves useful, and is tracked below as a follow-up rather than phase 2
scope.

## Follow-ups (not phase 2 scope)

- Promote the allowlist checker from a validation-time script to an inline
  request-path proxy (real gateway behavior: reject, not just report).
- Re-evaluate ToolHive (or similar) specifically for its Kubernetes
  operator story if Axle ever needs multi-host/fleet deployment -
  explicitly out of scope per phase-2-scope.md's "not yet decided" list.
- Extend the allowlist to chat-mcp's tool list too, per ADR-0002's own open
  question about whether the gateway (in whatever form) should be
  retrofitted in front of Chat MCP as well as the two new additions.
