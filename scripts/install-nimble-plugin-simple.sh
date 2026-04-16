#!/usr/bin/env bash
# NimbleStoragePlugin.pm — wget, install, restart; then scp to each host and same on remote.
# Edit REMOTES or set env: REMOTES="pve001 pve003" sudo ./install-nimble-plugin-simple.sh
set -euo pipefail

readonly TARGET='/usr/share/perl5/PVE/Storage/Custom/NimbleStoragePlugin.pm'
readonly DEFAULT_URL='https://raw.githubusercontent.com/brngates98/pve-nimble-plugin/main/NimbleStoragePlugin.pm'
PLUGIN_URL="${PLUGIN_URL:-$DEFAULT_URL}"
# Space-separated SSH hostnames (adjust to your nodes)
REMOTES="${REMOTES:-pve001 pve003}"

SERVICES=(pvedaemon pvestatd pveproxy pvescheduler)

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

# --- this host ---
[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }
command -v pveversion >/dev/null 2>&1 || { echo "Not a PVE host?" >&2; exit 1; }

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
echo "Local: downloading -> $TARGET"
download_to "$tmp"
install_from_tmp "$tmp"
restart_stack
echo "Local: done."

# --- remotes: copy the file we just installed, same path on each ---
for h in $REMOTES; do
  [[ -n "$h" ]] || continue
  echo "Remote $h: scp + install + restart"
  scp -o BatchMode=yes -o ConnectTimeout=15 "$TARGET" "root@${h}:/tmp/NimbleStoragePlugin.new"
  # shellcheck disable=SC2029
  ssh -o BatchMode=yes -o ConnectTimeout=15 "root@${h}" \
    "install -d -m 755 $(printf '%q' "$(dirname "$TARGET")") && \
     install -m 644 /tmp/NimbleStoragePlugin.new $(printf '%q' "$TARGET") && \
     rm -f /tmp/NimbleStoragePlugin.new && \
     if command -v deb-systemd-invoke >/dev/null 2>&1; then \
       for s in pvedaemon pvestatd pveproxy pvescheduler; do deb-systemd-invoke try-restart \${s}.service 2>/dev/null || true; done; \
     else \
       for s in pvedaemon pvestatd pveproxy pvescheduler; do systemctl try-restart \${s}.service 2>/dev/null || true; done; \
     fi"
  echo "Remote $h: done."
done

echo "All done."
