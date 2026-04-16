#!/usr/bin/env bash
# NimbleStoragePlugin.pm: curl/wget -> install + restart here, then scp to pve001 and pve003 and same there.
# Intended: run on pve002 with passwordless root SSH to pve001 / pve003.
#
#   sudo ./deploy-nimble-plugin-pm.sh
#
set -euo pipefail

readonly TARGET='/usr/share/perl5/PVE/Storage/Custom/NimbleStoragePlugin.pm'
readonly DEFAULT_URL='https://raw.githubusercontent.com/brngates98/pve-nimble-plugin/main/NimbleStoragePlugin.pm'
PLUGIN_URL="${PLUGIN_URL:-$DEFAULT_URL}"
REMOTES="${REMOTES:-pve001 pve003}"
THIS="$(hostname -s 2>/dev/null || hostname)"

SERVICES=(pvedaemon pvestatd pveproxy pvescheduler)

SSH_OPTS=( -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new )

restart_stack() {
  if command -v deb-systemd-invoke >/dev/null 2>&1; then
    for s in "${SERVICES[@]}"; do deb-systemd-invoke try-restart "${s}.service" 2>/dev/null || true; done
  else
    for s in "${SERVICES[@]}"; do systemctl try-restart "${s}.service" 2>/dev/null || true; done
  fi
}

download_to() {
  local out="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 20 --max-time 120 -o "$out" -- "$PLUGIN_URL"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --timeout=120 -O "$out" -- "$PLUGIN_URL"
  else
    echo "Need curl or wget" >&2
    exit 1
  fi
}

install_from_tmp() {
  local tmp="$1"
  head -n 1 "$tmp" | grep -q '^package PVE::Storage::Custom::NimbleStoragePlugin' || {
    echo "Not NimbleStoragePlugin.pm" >&2
    exit 1
  }
  install -d -m 755 "$(dirname "$TARGET")"
  install -m 644 "$tmp" "$TARGET"
}

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }
command -v pveversion >/dev/null 2>&1 || { echo "Not a PVE host?" >&2; exit 1; }

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
echo "Local: download -> $TARGET"
download_to "$tmp"
install_from_tmp "$tmp"
restart_stack
echo "Local: done."

echo "Also pushing to: $REMOTES"

for h in $REMOTES; do
  [[ -n "$h" ]] || continue
  if [[ "$h" == "$THIS" ]]; then
    echo "Skip $h (same as this host)"
    continue
  fi
  echo "Remote $h: scp then install + restart"
  scp "${SSH_OPTS[@]}" "$TARGET" "root@${h}:/tmp/NimbleStoragePlugin.new" || {
    echo "ERROR: scp to root@${h} failed (keys? DNS? firewall?)" >&2
    exit 1
  }
  ssh "${SSH_OPTS[@]}" "root@${h}" bash -s <<'REMOTE'
set -euo pipefail
T='/usr/share/perl5/PVE/Storage/Custom/NimbleStoragePlugin.pm'
install -d -m 755 "$(dirname "$T")"
install -m 644 /tmp/NimbleStoragePlugin.new "$T"
rm -f /tmp/NimbleStoragePlugin.new
if command -v deb-systemd-invoke >/dev/null 2>&1; then
  for s in pvedaemon pvestatd pveproxy pvescheduler; do
    deb-systemd-invoke try-restart "${s}.service" 2>/dev/null || true
  done
else
  for s in pvedaemon pvestatd pveproxy pvescheduler; do
    systemctl try-restart "${s}.service" 2>/dev/null || true
  done
fi
echo "remote: OK"
REMOTE
  echo "Remote $h: done."
done

echo "All done."
