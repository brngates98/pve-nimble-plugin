#!/bin/bash
# Syntax-check the **workspace** NimbleStoragePlugin.pm against a Proxmox
# release in Docker.  Supports bookworm (PVE 8) and trixie (PVE 9).
#
# Environment variables:
#   DIST                  Debian codename: bookworm (default) or trixie
#   VERIFY_DOCKER_IMAGE   Docker image (default: debian:<DIST>-slim)
#   DOCKER_PLATFORM       Docker platform (default: linux/amd64)
#
# Examples:
#   ./scripts/verify_plugin_in_docker.sh               # bookworm / PVE 8
#   DIST=trixie ./scripts/verify_plugin_in_docker.sh   # trixie  / PVE 9
#
# Requires: Docker
# On Apple Silicon, forces linux/amd64 (Proxmox packages are amd64).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

DIST="${DIST:-bookworm}"
IMAGE="${VERIFY_DOCKER_IMAGE:-debian:${DIST}-slim}"
PLATFORM="${DOCKER_PLATFORM:-linux/amd64}"

if ! command -v docker &>/dev/null; then
  echo "Error: docker not found" >&2
  exit 1
fi

echo "Verifying local workspace plugin in $IMAGE ($PLATFORM) [dist=$DIST]..."
docker run --rm -i \
  --platform "$PLATFORM" \
  -e DIST="$DIST" \
  -v "$PROJECT_DIR:/workspace:ro" \
  -w /workspace \
  "$IMAGE" \
  bash -s <<'DOCKER_SCRIPT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# cpio: required by proxmox-backup-file-restore postinst (pulled in with libpve-storage-perl deps)
apt-get install -y -qq ca-certificates wget cpio
printf '%s\n' '#!/bin/sh' 'exit 0' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d
wget -qO /etc/apt/trusted.gpg.d/proxmox-release.gpg \
  "https://enterprise.proxmox.com/debian/proxmox-release-${DIST}.gpg"
echo "deb [arch=amd64] http://download.proxmox.com/debian/pve ${DIST} pve-no-subscription" \
  > /etc/apt/sources.list.d/pve-install-repo.list
apt-get update -qq
apt-get install -y -qq \
  libpve-storage-perl \
  libjson-xs-perl \
  libwww-perl \
  liburi-perl

SRC=/workspace/NimbleStoragePlugin.pm
test -f "$SRC" || { echo "Error: missing $SRC (bind-mount the repo at /workspace)" >&2; exit 1; }

# Same relative path as dpkg install: PVE/Storage/Custom/NimbleStoragePlugin.pm
LAYOUT=/tmp/local-nimble-plugin-from-workspace
DST="$LAYOUT/PVE/Storage/Custom/NimbleStoragePlugin.pm"
mkdir -p "$(dirname "$DST")"
cp -a "$SRC" "$DST"
cmp -s "$SRC" "$DST" || { echo "Error: copy mismatch workspace -> $DST" >&2; exit 1; }

echo "Compiling plugin from workspace (not from any .deb): $DST"
perl -I"$LAYOUT" -I/usr/share/perl5 -c "$DST"
echo "perl -c (local workspace copy at PVE/Storage/Custom/): OK"

# Full load test: perl -c alone never exercises SectionConfig registration — PVE::Storage's
# init() runs when the module loads, BEFORE a plugin compiled from a temp path is registered.
# A property that collides with the global propertyList (e.g. redeclaring `port`, which the
# base class owns) passes perl -c but kills every PVE daemon on a real install. Install the
# plugin into the real Custom/ dir and load PVE::Storage so register + init actually run.
echo "Load test: registering plugin with PVE::Storage (SectionConfig init)..."
mkdir -p /usr/share/perl5/PVE/Storage/Custom
cp -a "$SRC" /usr/share/perl5/PVE/Storage/Custom/NimbleStoragePlugin.pm
perl -e '
  use strict; use warnings;
  use PVE::Storage;
  my $plugins = PVE::Storage::Plugin->private()->{plugins};
  die "plugin did not register as type nimble (check register-time warnings above)\n"
    unless $plugins->{nimble};
  # createSchema walks the merged propertyList + every plugin options(); catches dangling
  # options() references to properties nobody registered.
  PVE::Storage::Plugin->createSchema();
  print "PVE::Storage register + init + createSchema: OK\n";
'
DOCKER_SCRIPT
