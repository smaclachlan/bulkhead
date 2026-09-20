# ADR-0005: Build-Time Secret Injection for Private Workspace Dependencies

- Status: Accepted
- Date: 2026-09-20
- Supersedes: none
- Amends: none
- Related: [README.md](../../README.md) ("Custom workspace image" section),
  [ADR-0001](0001-phase-1-four-container-architecture.md) §4 (Workspace has
  no network), [ADR-0004](0004-git-mcp-bundle-relay.md)

## Context

A custom `WORKSPACE_DOCKERFILE_DIR` build environment (README cornerstone 7)
sometimes needs to fetch other git repositories as part of its own setup -
a multi-repo manifest tool (e.g. Zephyr's `west update`) rather than a
single `git clone`. `workspace` has no network at all (ADR-0001 §4), and
Git MCP's egress is scoped to exactly one pre-configured remote (ADR-0003/
0004) - neither is the right place for "fetch N repositories this build
happens to need," and widening either would cut against the narrow,
enumerated-egress design both were built for.

`docker build` runs on the host, before any of `docker-compose.yml`'s
network segmentation exists - it already has ordinary internet access with
no config needed, and is the natural place to resolve this once, outside
the sandbox, rather than the workspace resolving it live inside. This
mirrors how the project already treats reproducible inputs: `workspace/
default.nix` is itself a Nix derivation, and Nix's whole model is pinning
inputs ahead of time rather than re-resolving them at runtime.

The remaining problem is credentials: some of those repositories are
private, and a build-time fetch needs a token/key to reach them without
that credential ending up anywhere it could later leak - baked into an
image layer, visible in `docker history`, or (worse) present at runtime in
a container an agent can run arbitrary commands in.

## Decision

### 1. BuildKit `--secret`, not `--build-arg` or a baked-in file

`WORKSPACE_BUILD_SECRET_HOST_PATH` (a file on the host, never committed)
and `WORKSPACE_BUILD_SECRET_ID` are read by `nix run .#up` and passed to
`docker build` as `--secret id=<id>,src=<path>`, with `DOCKER_BUILDKIT=1`
exported for every image build in the flake. A `RUN --mount=type=secret,
id=<id>` in the Dockerfile mounts it at `/run/secrets/<id>` for only that
one instruction - it is never written to any layer, never appears in
`docker history`, and the resulting image carries no trace of it. Compare
the two rejected alternatives: a `--build-arg` is plaintext in the image's
build history forever; a file copied into the build context and later
`rm`'d still leaves its bytes in the layer that copied it, recoverable by
anyone who can pull the image.

The README's Dockerfile example reads the secret via `GIT_ASKPASS` rather
than a git credential helper or `http.extraheader` written to
`~/.gitconfig` - the askpass script only ever contains a `cat
/run/secrets/<id>`, never the secret value itself, so there's no discipline
required around remembering to unset a config value before the `RUN`
instruction ends (the earlier, rejected approach - see Alternatives).

### 2. Layer ordering is part of the decision, not just style advice

Without deliberate ordering (manifest-only `COPY` before the vendoring
`RUN`, the `RUN` itself last), this degrades from "resolved once at build
time" back into "resolved on every `nix run .#up`" - Docker's cache is
strictly sequential, so an unrelated earlier change (or a broad `COPY . .`)
invalidates everything after it, forcing a full re-fetch (network + the
secret) on every routine bring-up rather than only when the manifest
actually changes. This doesn't weaken the security property (the secret is
still never persisted) but it defeats the entire point of doing this at
build time instead of runtime, so it's documented as a required pattern in
README, not an optional optimization.

### 3. Label + prune, so vendored layers don't accumulate unbounded

Every image `nix run .#up`/`build-*-image` builds carries a `bulkhead=1`
label. `nix run .#prune-images` removes dangling (superseded, untagged)
images scoped to that label - not a blanket `docker image prune` across
the whole host, which would also reclaim unrelated projects' images on the
same Docker daemon. A vendored dependency tree can be a large, unique top
layer; each rebuild that changes it leaves the previous one behind
otherwise. `--builder-cache` additionally prunes BuildKit's whole build
cache on request - deliberately *not* scoped, and off by default, since
narrowing that reclaims cache for every project using the daemon, not just
this one.

This doesn't require knowing which layers are "the vendored one" versus
"the shared base" - Docker's layers are content-addressable, so pruning a
dangling image only frees what's actually unique to it; anything still
shared with the current build (the base/toolchain layers, if ordering per
Decision 2 held) stays referenced and cached regardless.

## Consequences

**Positive**
- Zero increase in runtime attack surface - the secret exists only in the
  host's `docker build` process, which already had unrestricted network and
  was already trusted (see below); nothing about `workspace`'s
  `network_mode: none` or any MCP server's tool surface changes.
- Reuses a pattern the project already trusts (Nix-style pinned, resolved-
  once inputs) rather than inventing a new one.
- The label/prune mechanism generalizes past this one feature - any future
  large or frequently-rebuilt image gets the same cleanup path for free.

**Negative / accepted risk**
- This is explicitly build-time, operator-side trust, not agent
  containment - consistent with README's Threat Model already scoping out
  "a malicious user who already has full control of the Orchestrator,"
  extended here to whoever configures/builds a custom `WORKSPACE_DOCKERFILE_DIR`.
  A Dockerfile that mishandles the secret (e.g. an author writing it to a
  file themselves instead of using the askpass pattern) isn't something
  this ADR's mechanism can prevent - it removes the footguns in Bulkhead's
  own plumbing, not in an operator's own Dockerfile content.
- Requires BuildKit (`DOCKER_BUILDKIT=1`, now exported for all image builds
  in the flake) - not a new constraint in practice, since it's been Docker's
  default builder for years, but worth naming as a hard requirement for
  `--secret` specifically to work at all.

**Follow-ups tracked for later**
- An SSH-key variant of the same pattern (`--secret` mounting a private key
  instead of a token, for manifests using SSH remotes) - not built, since
  the README example only covers the HTTPS-PAT case; the mechanism
  (BuildKit `--secret`, consumed only inside one `RUN`) is identical either
  way.

## Alternatives Considered

- **`docker build --build-arg`.** Rejected - build args are recorded in
  plain text in the image's build history indefinitely; trivially
  recoverable by anyone who can inspect the image.
- **Copy the secret file into the build context, use it, delete it in a
  later `RUN`.** Rejected - each `RUN` commits a layer; a later layer
  deleting a file leaves a whiteout marker, not an erased history - the
  secret's bytes are still present in the earlier layer's blob.
- **`git config --global` (a credential helper or `http.extraheader`) set
  and unset within one `RUN`, instead of `GIT_ASKPASS`.** Would also avoid
  persisting the secret (a single `RUN` only commits the *final* filesystem
  state), but depends on remembering to unset it correctly before that one
  `RUN` ends - the askpass script never contains the secret value at all,
  removing that failure mode entirely rather than relying on getting the
  set/unset pair right.
- **Give `workspace` scoped live network access (a domain-allowlisted
  egress proxy) instead of vendoring at build time.** Rejected - reopens a
  live path from the sandbox's arbitrary-code zone to the internet, the
  single strongest property this project has, for a problem that build-time
  resolution already solves with zero runtime exposure.
- **A runtime pre-step that gives `workspace` a real network, runs the
  fetch, then `docker network disconnect`s it before the agent's turn.**
  Considered and rejected - achieves the same end state as build-time
  vendoring but replaces a structural guarantee (`network_mode: none`,
  nothing to misconfigure) with an imperative one that has to be sequenced
  correctly on every boot, including after a crash/`restart: on-failure`
  cycle, and only stays as safe as build-time vendoring if it's fixed and
  boot-only rather than ever re-triggerable by the agent - at which point
  it's the same category of regression as the egress-proxy option above.
