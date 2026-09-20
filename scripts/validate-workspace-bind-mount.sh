#!/usr/bin/env bash
# Standalone harness for the WORKSPACE_HOST_PATH / WORKSPACE_USER feature
# (docker-compose.yml's `workspace` service, flake.nix's `up`/
# `reset-workspace` apps, workspace/default.nix) - not tied to a numbered
# phase, this is a small opt-in addition to the existing workspace volume
# config, not a new architectural milestone.
#
# Works against whichever profile you point it at, and checks different
# things depending on what that profile actually set:
#   - No WORKSPACE_HOST_PATH: regression guard that the default
#     internal-only named volume and its pre-chowned 10001:10001 user
#     (workspace/default.nix) still work exactly as before this feature
#     was added.
#   - WORKSPACE_HOST_PATH set: checks the bind mount actually replaced the
#     named volume, that the container's user matches WORKSPACE_USER (or,
#     if that's unset, your own uid:gid - see flake.nix's `up`), that a
#     file written inside the container is visible on the host and vice
#     versa, and that `nix run .#reset-workspace` doesn't lose any of this.
#
# Run from the repo root, with the target profile's stack already up:
#   sh scripts/validate-workspace-bind-mount.sh [env-file]
#
# [env-file] is optional, same profile convention as `nix run .#up` (see
# README's Profiles section) - defaults to .env, but that only exercises
# the no-bind-mount branch above unless you've set WORKSPACE_HOST_PATH in
# it yourself. scripts/test-profiles/bind-mount-*.conf.example are ready-
# made profiles for the bind-mount branch - copy one, fill it in per its
# own header comment, bring it up, then point this script at it, e.g.:
#   sh scripts/validate-workspace-bind-mount.sh ./bind-mount-auto.conf
#
# Requires: docker, docker compose, python3 on PATH.

set -u

env_file="${1:-.env}"
HARNESS="workspace-bind-mount"
RESULTS_TSV="$(mktemp)"
trap 'rm -f "$RESULTS_TSV"' EXIT

pass=0
fail=0

# record/skip - same TSV-then-JSON pattern as scripts/validate-phase3.sh,
# kept local here rather than shared since this is the one script outside
# the phase-N set.
record() {
  id="$1"; status="$2"; desc="$3"; detail="${4:-}"
  detail_one_line="$(printf '%s' "$detail" | tr '\n' '|' | sed 's/|/ | /g')"
  printf '%s\t%s\t%s\t%s\n' "$id" "$status" "$desc" "$detail_one_line" >> "$RESULTS_TSV"
  if [ "$status" = "pass" ]; then
    printf '[PASS] %s\n' "$desc"
    pass=$((pass + 1))
  else
    printf '[FAIL] %s\n' "$desc"
    [ -n "$detail" ] && printf '       %s\n' "$detail_one_line"
    fail=$((fail + 1))
  fi
}

skip() {
  id="$1"; desc="$2"; detail="${3:-}"
  detail_one_line="$(printf '%s' "$detail" | tr '\n' '|' | sed 's/|/ | /g')"
  printf '%s\t%s\t%s\t%s\n' "$id" "skip" "$desc" "$detail_one_line" >> "$RESULTS_TSV"
  printf '[SKIP] %s\n' "$desc"
}

abort() {
  echo "$1" >&2
  exit 1
}

if [ ! -f flake.nix ] || [ ! -f docker-compose.yml ]; then
  abort "run this from the bulkhead repo root"
fi

command -v docker >/dev/null 2>&1 || abort "docker not found on PATH"
command -v python3 >/dev/null 2>&1 || abort "python3 not found on PATH"
[ -f "$env_file" ] || abort "env file '$env_file' not found"

. scripts/lib/profile.sh
bulkhead_resolve_profile "$env_file" || abort "invalid env file '$env_file'"
set -a
. "$env_file"
set +a

dc() {
  docker compose -p "$BULKHEAD_PROJECT_NAME" --env-file "$env_file" "$@"
}

dc ps >/dev/null 2>&1 || abort "'docker compose -p $BULKHEAD_PROJECT_NAME ps' failed - is this profile's stack up (nix run .#up -- $env_file)?"

container_id="$(dc ps -q workspace)"
[ -n "$container_id" ] || abort "no running 'workspace' container for project $BULKHEAD_PROJECT_NAME"

repo_path="${WORKSPACE_REPO_PATH:-/repo}"

echo "== workspace-bind-mount harness: profile=$BULKHEAD_PROJECT_NAME repo_path=$repo_path host_path=${WORKSPACE_HOST_PATH:-<unset>} user=${WORKSPACE_USER:-<unset>} =="

# ---- Step 1: mount type matches what WORKSPACE_HOST_PATH implies --------

echo
echo "== Step 1: /repo mount type =="

mount_json="$(docker inspect "$container_id" --format '{{json .Mounts}}' 2>&1)"
mount_info="$(printf '%s' "$mount_json" | python3 -c "
import json, sys
try:
    mounts = json.load(sys.stdin)
except Exception as e:
    print(f'parse-error:{e}')
    sys.exit(0)
for m in mounts:
    if m.get('Destination') == '$repo_path':
        print(f\"{m.get('Type')}\t{m.get('Source', '')}\")
        break
else:
    print('not-found')
")"

mount_type="$(printf '%s' "$mount_info" | cut -f1)"
mount_source="$(printf '%s' "$mount_info" | cut -f2)"

if [ -n "${WORKSPACE_HOST_PATH:-}" ]; then
  abs_host_path="$(readlink -f "$WORKSPACE_HOST_PATH" 2>/dev/null || echo "$WORKSPACE_HOST_PATH")"
  if [ "$mount_type" = "bind" ] && [ "$mount_source" = "$abs_host_path" ]; then
    record step1.mount-type pass "$repo_path is a bind mount of WORKSPACE_HOST_PATH" "$mount_info"
  else
    record step1.mount-type fail "$repo_path is a bind mount of WORKSPACE_HOST_PATH" "expected bind:$abs_host_path, got $mount_info"
  fi
else
  if [ "$mount_type" = "volume" ]; then
    record step1.mount-type pass "$repo_path is the default named volume (no WORKSPACE_HOST_PATH set)" "$mount_info"
  else
    record step1.mount-type fail "$repo_path is the default named volume (no WORKSPACE_HOST_PATH set)" "expected volume, got $mount_info"
  fi
fi

# ---- Step 2: container user matches WORKSPACE_USER (or its default) -----

echo
echo "== Step 2: container user =="

actual_user="$(dc exec -T workspace sh -c 'id -u; id -g' 2>&1 | tr '\n' ':' | sed 's/:$//')"

if [ -n "${WORKSPACE_USER:-}" ]; then
  expected_user="$WORKSPACE_USER"
  check_label="matches explicit WORKSPACE_USER=$expected_user"
elif [ -n "${WORKSPACE_HOST_PATH:-}" ]; then
  expected_user="$(id -u):$(id -g)"
  check_label="matches this shell's own uid:gid (auto-default, since WORKSPACE_HOST_PATH is set and WORKSPACE_USER wasn't)"
else
  expected_user="10001:10001"
  check_label="matches workspace/default.nix's baked-in default (no WORKSPACE_HOST_PATH/WORKSPACE_USER set)"
fi

if [ "$actual_user" = "$expected_user" ]; then
  record step2.container-user pass "container user $check_label" "actual=$actual_user"
else
  record step2.container-user fail "container user $check_label" "expected=$expected_user actual=$actual_user"
fi

# ---- Step 3: the mount is actually writable, and (if a bind mount) the --
# ---- host sees what the container writes and vice versa ----------------

echo
echo "== Step 3: read/write round-trip =="

marker="bulkhead-bind-mount-check-$(date +%s)"
container_marker_path="${repo_path}/${marker}"

write_result="$(dc exec -T workspace sh -c "echo from-container > '$container_marker_path'" 2>&1)"
write_status=$?

if [ "$write_status" -ne 0 ]; then
  record step3.container-write fail "workspace can write into $repo_path" "$write_result"
else
  record step3.container-write pass "workspace can write into $repo_path"

  if [ -n "${WORKSPACE_HOST_PATH:-}" ]; then
    host_marker_path="${WORKSPACE_HOST_PATH%/}/${marker}"
    if [ -f "$host_marker_path" ] && [ "$(cat "$host_marker_path" 2>/dev/null)" = "from-container" ]; then
      record step3.host-sees-container-write pass "a file the container wrote is visible on the host at $host_marker_path"
    else
      record step3.host-sees-container-write fail "a file the container wrote is visible on the host at $host_marker_path" "not found, or content mismatch"
    fi

    printf 'from-host\n' > "${WORKSPACE_HOST_PATH%/}/${marker}.host" 2>/dev/null
    seen_from_container="$(dc exec -T workspace sh -c "cat '${repo_path}/${marker}.host' 2>/dev/null")"
    if [ "$seen_from_container" = "from-host" ]; then
      record step3.container-sees-host-write pass "a file written from the host is visible inside the container"
    else
      record step3.container-sees-host-write fail "a file written from the host is visible inside the container" "got: $seen_from_container"
    fi
    rm -f "${WORKSPACE_HOST_PATH%/}/${marker}.host" 2>/dev/null
  else
    skip step3.host-sees-container-write "host-visibility checks (no WORKSPACE_HOST_PATH set - nothing on the host to check)"
    skip step3.container-sees-host-write "host-visibility checks (no WORKSPACE_HOST_PATH set - nothing on the host to check)"
  fi

  dc exec -T workspace sh -c "rm -f '$container_marker_path'" >/dev/null 2>&1
fi

# ---- Step 4: reset-workspace doesn't lose WORKSPACE_USER ----------------
# Only meaningful with a bind mount - this is the exact bug the
# WORKSPACE_USER auto-default logic had to be added to flake.nix's
# reset-workspace app too, not just `up`, to avoid (see its comment there).

echo
echo "== Step 4: nix run .#reset-workspace preserves the container user =="

if [ -n "${WORKSPACE_HOST_PATH:-}" ]; then
  if command -v nix >/dev/null 2>&1; then
    reset_output="$(nix run .#reset-workspace -- "$env_file" 2>&1)"
    reset_status=$?
    if [ "$reset_status" -ne 0 ]; then
      record step4.reset-preserves-user fail "reset-workspace succeeds" "$reset_output"
    else
      # Container was recreated - re-fetch its id and re-check the user.
      container_id="$(dc ps -q workspace)"
      actual_user_after="$(dc exec -T workspace sh -c 'id -u; id -g' 2>&1 | tr '\n' ':' | sed 's/:$//')"
      if [ "$actual_user_after" = "$expected_user" ]; then
        record step4.reset-preserves-user pass "container user still $check_label after reset-workspace" "actual=$actual_user_after"
      else
        record step4.reset-preserves-user fail "container user still $check_label after reset-workspace" "expected=$expected_user actual=$actual_user_after"
      fi
    fi
  else
    skip step4.reset-preserves-user "reset-workspace check (nix not found on PATH)"
  fi
else
  skip step4.reset-preserves-user "reset-workspace check (only meaningful with WORKSPACE_HOST_PATH set)"
fi

# ---- Write the attestation record --------------------------------------

echo
echo "== Summary: $pass passed, $fail failed =="

if [ "$BULKHEAD_PROJECT_NAME" = "bulkhead" ]; then
  RESULTS_DIR="validation-results/${HARNESS}"
else
  RESULTS_DIR="validation-results/${HARNESS}/profiles/${BULKHEAD_PROJECT_NAME}"
fi
mkdir -p "$RESULTS_DIR"
ts="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
out_file="${RESULTS_DIR}/${ts}.json"
git_commit="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
git_dirty="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"

python3 -c "
import json, sys

rows = []
with open(sys.argv[1], encoding='utf-8') as f:
    for line in f:
        line = line.rstrip('\n')
        if not line:
            continue
        parts = line.split('\t')
        parts += [''] * (4 - len(parts))
        rows.append({
            'id': parts[0],
            'status': parts[1],
            'description': parts[2],
            'detail': parts[3],
        })

record = {
    'harness': sys.argv[2],
    'timestamp_utc': sys.argv[3],
    'git_commit': sys.argv[4],
    'git_dirty': sys.argv[5] != '0',
    'project': sys.argv[7],
    'checks': rows,
    'summary': {
        'pass': sum(1 for r in rows if r['status'] == 'pass'),
        'fail': sum(1 for r in rows if r['status'] == 'fail'),
        'skip': sum(1 for r in rows if r['status'] == 'skip'),
        'total': len(rows),
    },
}

with open(sys.argv[6], 'w', encoding='utf-8') as f:
    json.dump(record, f, indent=2)
    f.write('\n')
" "$RESULTS_TSV" "$HARNESS" "$ts" "$git_commit" "$git_dirty" "$out_file" "$BULKHEAD_PROJECT_NAME"

cp "$out_file" "${RESULTS_DIR}/latest.json"
echo "Results written to ${out_file} (and ${RESULTS_DIR}/latest.json)"

[ "$fail" -eq 0 ]
