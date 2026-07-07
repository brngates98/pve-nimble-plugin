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

# Parse test (nimble-only install): legacy pre-v0.0.25 keys must still parse and be canonicalized
# to the nimble_-prefixed spellings by check_config; canonical keys must parse as-is.
echo "Parse test: legacy + canonical storage.cfg keys (nimble-only)..."
cat > /tmp/nimble_parse_test.pl <<'PARSETEST'
use strict; use warnings;
use PVE::Storage;
my $raw = <<'CFG';
nimble: legacy
	address array1.example
	username admin
	vnprefix pve-
	check_ssl 0
	token_ttl 1800
	debug 1
	pool_name default
	initiator_group ig1
	content images

nimble: canonical
	nimble_address array2.example
	username admin
	nimble_vnprefix pve-
	content images
CFG
my $cfg = PVE::Storage::Plugin->parse_config('storage.cfg', $raw);
die "parse errors: " . join(', ', map { "$_->{key}: $_->{err}" } @{ $cfg->{errors} }) if $cfg->{errors};
my $l = $cfg->{ids}{legacy} or die "legacy section missing\n";
die "legacy address not canonicalized\n"    unless ($l->{nimble_address}    // '') eq 'array1.example';
die "legacy pool_name not canonicalized\n"  unless ($l->{nimble_pool_name}  // '') eq 'default';
die "legacy token_ttl not canonicalized\n"  unless ($l->{nimble_token_ttl}  // 0)  == 1800;
die "legacy key still present after canonicalization\n" if exists $l->{address};
my $c = $cfg->{ids}{canonical} or die "canonical section missing\n";
die "canonical nimble_address missing\n" unless ($c->{nimble_address} // '') eq 'array2.example';
print "storage.cfg parse + legacy-key canonicalization: OK\n";
PARSETEST
perl /tmp/nimble_parse_test.pl

# Co-install test: install a fake plugin that (like pve-purestorage-plugin) declares the generic
# names address/vnprefix/check_ssl/token_ttl/debug. SectionConfig::init() merges plugins in random
# hash order per process, so run 10 fresh perl processes to exercise both merge orders. Any
# redeclaration by either plugin would die "duplicate property"; the nimble plugin must instead
# skip declaring the claimed legacy names (registered-plugin scan) while keeping its canonical
# nimble_* names — and legacy storage.cfg keys must STILL parse via the rival plugin's property.
echo "Co-install test: fake rival plugin owning address/vnprefix/check_ssl/token_ttl/debug..."
cat > /usr/share/perl5/PVE/Storage/Custom/FakePureStoragePlugin.pm <<'FAKEPLUGIN'
package PVE::Storage::Custom::FakePureStoragePlugin;
use strict; use warnings;
use PVE::Storage::Plugin;
use base qw(PVE::Storage::Plugin);
sub api  { return PVE::Storage::APIVER(); }
sub type { return 'fakepure'; }
sub plugindata {
  return { content => [ { images => 1, none => 1 }, { images => 1 } ], format => [ { raw => 1 }, 'raw' ] };
}
sub properties {
  return {
    address   => { description => 'addr',  type => 'string' },
    token     => { description => 'token', type => 'string' },
    vnprefix  => { description => 'pfx',   type => 'string' },
    check_ssl => { description => 'ssl',   type => 'boolean', default => 'no' },
    token_ttl => { description => 'ttl',   type => 'integer', default => 3600 },
    debug     => { description => 'dbg',   type => 'integer', minimum => 0, maximum => 3, default => 0 },
  };
}
sub options {
  return {
    address   => { fixed => 1 },
    token     => { fixed => 1 },
    vnprefix  => { optional => 1 },
    check_ssl => { optional => 1 },
    token_ttl => { optional => 1 },
    debug     => { optional => 1 },
    nodes     => { optional => 1 },
    disable   => { optional => 1 },
    content   => { optional => 1 },
    format    => { optional => 1 },
  };
}
1;
FAKEPLUGIN
cat > /tmp/nimble_coinstall_test.pl <<'COINSTALL'
use strict; use warnings;
use PVE::Storage;
my $plugins = PVE::Storage::Plugin->private()->{plugins};
die "nimble did not register\n"   unless $plugins->{nimble};
die "fakepure did not register\n" unless $plugins->{fakepure};
PVE::Storage::Plugin->createSchema();
my $pl = PVE::Storage::Plugin->private()->{propertyList};
for my $p (qw(address vnprefix check_ssl token_ttl debug)) {
  die "shared property '$p' missing from propertyList\n" unless $pl->{$p};
}
for my $p (qw(nimble_address nimble_vnprefix nimble_check_ssl nimble_token_ttl nimble_debug
              nimble_pool_name nimble_initiator_group nimble_volume_collection)) {
  die "canonical property '$p' missing from propertyList\n" unless $pl->{$p};
}
# Legacy nimble section must still parse (shared names resolve via the rival plugin's property).
my $raw = "nimble: legacy\n\taddress array1.example\n\tusername admin\n\tdebug 1\n\tcontent images\n";
my $cfg = PVE::Storage::Plugin->parse_config('storage.cfg', $raw);
die "co-install parse errors\n" if $cfg->{errors};
my $l = $cfg->{ids}{legacy} or die "legacy section missing\n";
die "legacy address not canonicalized under co-install\n"
  unless ($l->{nimble_address} // '') eq 'array1.example';
print "co-install iteration OK\n";
COINSTALL
for i in $(seq 1 10); do
  perl /tmp/nimble_coinstall_test.pl \
    || { echo "Co-install load test FAILED on iteration $i" >&2; exit 1; }
done
rm -f /usr/share/perl5/PVE/Storage/Custom/FakePureStoragePlugin.pm
echo "Co-install load test (10 random-hash-order inits): OK"
DOCKER_SCRIPT
