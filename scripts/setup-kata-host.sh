#!/usr/bin/env bash
# Host bootstrap for ADR-0002 Decision 1 (Kata Containers for the Workspace
# container) - see README's "Kata Containers setup" section. Installs
# Docker (if missing) and Kata Containers (if missing), then registers
# `kata` as a Docker runtime. Debian/Ubuntu (apt) only - see that README
# section for why (nixpkgs only ships Kata's shim binary, not the guest
# kernel/rootfs image it also needs).
#
# Idempotent - every step checks current state first and skips if already
# satisfied. Safe to re-run. Run as your normal user, not via sudo - it
# escalates individual commands itself:
#   sh scripts/setup-kata-host.sh
#
# Re-download/re-extract Kata even if already installed:
#   sh scripts/setup-kata-host.sh --force

set -euo pipefail

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

log() { printf '==> %s\n' "$1"; }
warn() { printf 'warning: %s\n' "$1" >&2; }

command -v apt-get >/dev/null 2>&1 || {
  echo "error: apt-get not found - this script only supports Debian/Ubuntu hosts" >&2
  exit 1
}

REAL_USER="$(id -un)"
KATA_SHIM=/opt/kata/runtime-rs/bin/containerd-shim-kata-v2
KATA_QEMU_CONFIG=/opt/kata/share/defaults/kata-containers/runtime-rs/configuration-qemu-runtime-rs.toml

# ---- Prerequisites ------------------------------------------------------

log "Installing prerequisites (curl, jq, zstd, ca-certificates)..."
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends curl jq zstd ca-certificates

# ---- Docker --------------------------------------------------------------

if command -v docker >/dev/null 2>&1; then
  log "Docker already installed ($(docker --version)) - skipping install"
else
  log "Installing Docker (docker.io + compose plugin) via apt..."
  sudo apt-get install -y docker.io docker-compose-v2
fi

if ! systemctl is-active --quiet docker 2>/dev/null; then
  log "Starting/enabling the Docker service..."
  sudo systemctl enable --now docker
fi

if ! id -nG "$REAL_USER" | tr ' ' '\n' | grep -qx docker; then
  log "Adding $REAL_USER to the docker group (log out/in, or 'newgrp docker', for this to take effect)..."
  sudo usermod -aG docker "$REAL_USER"
fi

# ---- KVM -------------------------------------------------------------

if [ ! -e /dev/kvm ]; then
  warn "/dev/kvm not found - Kata needs hardware virtualization. If this host is itself a VM, enable nested virtualization first."
else
  log "/dev/kvm present"
  if ! id -nG "$REAL_USER" | tr ' ' '\n' | grep -qx kvm; then
    log "Adding $REAL_USER to the kvm group..."
    sudo usermod -aG kvm "$REAL_USER"
  fi
fi

# ---- Kata Containers -----------------------------------------------------

if [ -x "$KATA_SHIM" ] && [ "$FORCE" -eq 0 ]; then
  log "Kata already installed at $KATA_SHIM - skipping download (use --force to redo)"
else
  case "$(uname -m)" in
    x86_64) ARCH=amd64 ;;
    aarch64) ARCH=arm64 ;;
    s390x) ARCH=s390x ;;
    ppc64le) ARCH=ppc64le ;;
    *)
      echo "error: unsupported architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac

  VERSION="$(curl -sSL https://api.github.com/repos/kata-containers/kata-containers/releases/latest | jq -r .tag_name)"
  log "Downloading Kata ${VERSION} for ${ARCH}..."

  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' EXIT
  curl -fsSL -o "${workdir}/kata-static.tar.zst" \
    "https://github.com/kata-containers/kata-containers/releases/download/${VERSION}/kata-static-${VERSION}-${ARCH}.tar.zst"

  log "Extracting to /opt/kata..."
  sudo tar -xf "${workdir}/kata-static.tar.zst" -C /

  [ -x "$KATA_SHIM" ] || {
    echo "error: extraction finished but $KATA_SHIM is still missing - Kata's release layout may have changed" >&2
    exit 1
  }
fi

# ---- Register the runtime with Docker ------------------------------------

merge_py="
import json, pathlib, sys

path = pathlib.Path('/etc/docker/daemon.json')
desired = {
    'runtimeType': '${KATA_SHIM}',
    'options': {'ConfigPath': '${KATA_QEMU_CONFIG}'},
}

if path.exists() and path.stat().st_size:
    try:
        config = json.loads(path.read_text())
    except json.JSONDecodeError as e:
        print(f'ERROR not valid JSON: {e}')
        sys.exit(1)
else:
    config = {}

runtimes = config.setdefault('runtimes', {})
if runtimes.get('kata') == desired:
    print('UNCHANGED')
else:
    runtimes['kata'] = desired
    path.write_text(json.dumps(config, indent=2) + '\n')
    print('CHANGED')
"

result="$(sudo python3 -c "$merge_py")" || true
case "$result" in
  UNCHANGED)
    log "/etc/docker/daemon.json already has the kata runtime registered"
    ;;
  CHANGED)
    log "/etc/docker/daemon.json updated - restarting Docker..."
    sudo systemctl restart docker
    ;;
  *)
    # Covers the python side's own "ERROR ..." message (e.g. daemon.json
    # isn't valid JSON) as well as anything truly unexpected - `|| true`
    # above stops a non-zero exit there from being swallowed silently by
    # `set -e` before this message ever gets shown.
    echo "error: failed to update /etc/docker/daemon.json: $result" >&2
    exit 1
    ;;
esac

# ---- Validate --------------------------------------------------------------

log "Validating: running uname -r under --runtime kata vs. the host..."
# sudo, not plain `docker` - a docker-group membership just granted above
# doesn't take effect in this same shell (needs a fresh login/newgrp), so
# an unprivileged call here would spuriously fail on a first-ever run.
host_kernel="$(uname -r)"
guest_kernel="$(sudo docker run --runtime kata --rm ubuntu:24.04 uname -r 2>&1)" || {
  echo "error: 'docker run --runtime kata' failed:" >&2
  echo "$guest_kernel" >&2
  exit 1
}

echo "  host kernel:  $host_kernel"
echo "  guest kernel: $guest_kernel"
if [ "$host_kernel" = "$guest_kernel" ]; then
  warn "guest kernel matches the host's - Kata may not actually be engaging"
  exit 1
fi

log "Kata is working. Set WORKSPACE_RUNTIME=kata in .env and re-run 'nix run .#up'."
