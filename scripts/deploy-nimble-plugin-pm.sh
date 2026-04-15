#!/usr/bin/env bash
##############################################################################
# Deploy NimbleStoragePlugin.pm on Proxmox VE (single node or whole cluster).
#
# Downloads the plugin from a URL (default: main branch on GitHub), installs
# to /usr/share/perl5/PVE/Storage/Custom/, and restarts PVE services so Perl
# reloads the module — same units as debian/postinst (no pve-cluster).
#
# Usage (single node):
#   sudo bash scripts/deploy-nimble-plugin-pm.sh
#   sudo PLUGIN_URL=https://example.com/NimbleStoragePlugin.pm bash ...
#
# All cluster nodes (SSH as root to peers; each node pulls the same URL):
#   sudo bash scripts/deploy-nimble-plugin-pm.sh --all-nodes
#
# Note: If you install libpve-storage-nimble-perl from APT, the next package
# upgrade may replace this file. Prefer APT upgrades when possible; use this
# for hot-fixes or testing a specific revision from git.
##############################################################################

set -euo pipefail

readonly TARGET='/usr/share/perl5/PVE/Storage/Custom/NimbleStoragePlugin.pm'
readonly PVE_MEMBERS_FILE='/etc/pve/.members'
# Same as scripts/install-pve-nimble-plugin.sh / debian/postinst
readonly RESTART_SERVICES=(pvedaemon pvestatd pveproxy pvescheduler)
readonly DEFAULT_PLUGIN_URL='https://raw.githubusercontent.com/brngates98/pve-nimble-plugin/main/NimbleStoragePlugin.pm'
# Used for --all-nodes remotes (each node curls this script, then runs single-node deploy)
readonly DEFAULT_DEPLOY_SCRIPT_URL='https://raw.githubusercontent.com/brngates98/pve-nimble-plugin/main/scripts/deploy-nimble-plugin-pm.sh'

PLUGIN_URL="${PLUGIN_URL:-$DEFAULT_PLUGIN_URL}"
DEPLOY_SCRIPT_URL="${DEPLOY_SCRIPT_URL:-$DEFAULT_DEPLOY_SCRIPT_URL}"
DRY_RUN=0
ALL_NODES=0
VERBOSE=0

log() { printf '%b\n' "$*"; }
fail() { log "ERROR: $*"; exit 1; }

usage() {
    cat <<EOF
Usage: ${0##*/} [options]

  -u, --url URL     Fetch NimbleStoragePlugin.pm from URL (default: main on GitHub)
  -a, --all-nodes   Deploy on all nodes in the cluster (SSH root@<node-ip>)
  -n, --dry-run     Print actions only
  -v, --verbose     More output
  -h, --help        This help

Environment:
  PLUGIN_URL           Same as --url
  DEPLOY_SCRIPT_URL    Used with --all-nodes on SSH peers (default: main script on GitHub)

Examples:
  curl -fsSL .../deploy-nimble-plugin-pm.sh | sudo bash
  sudo PLUGIN_URL=https://raw.githubusercontent.com/USER/REPO/REF/NimbleStoragePlugin.pm bash deploy-nimble-plugin-pm.sh
EOF
}

restart_pve_stack() {
    local cmd
    if command -v deb-systemd-invoke >/dev/null 2>&1; then
        cmd=(deb-systemd-invoke)
    else
        cmd=(systemctl)
    fi
    local s
    for s in "${RESTART_SERVICES[@]}"; do
        "${cmd[@]}" try-restart "${s}.service" 2>/dev/null || true
    done
}

download_to_file() {
    local url="$1"
    local out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$out" -- "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$out" -- "$url"
    else
        fail "Need curl or wget to download"
    fi
}

install_plugin_file() {
    local url="$1"
    local tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/nimble-plugin.XXXXXX")"
    # shellcheck disable=SC2064
    trap 'rm -f "$tmp"' RETURN

    log "Downloading: $url"
    download_to_file "$url" "$tmp"

    if ! head -n 1 "$tmp" | grep -q '^package PVE::Storage::Custom::NimbleStoragePlugin'; then
        fail "Download does not look like NimbleStoragePlugin.pm (missing expected package line)"
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "DRY-RUN: would install to $TARGET and restart: ${RESTART_SERVICES[*]}"
        return
    fi

    install -d -m 755 "$(dirname "$TARGET")"
    install -m 644 "$tmp" "$TARGET"
    log "Installed: $TARGET"
    log "Restarting: ${RESTART_SERVICES[*]}"
    restart_pve_stack
}

enumerate_cluster_nodes() {
    perl -MJSON -0777 -e '
        my $j = from_json(<STDIN>);
        my %seen;
        for (values %{$j->{nodelist}}) {
            my $ip = $_->{ip} // next;
            print "$ip\n" unless $seen{$ip}++;
        }
    ' "$PVE_MEMBERS_FILE"
}

is_cluster() {
    perl -MJSON -0777 -e '
        my $j = from_json(<STDIN>);
        exit(defined($j->{cluster}) ? 0 : 1);
    ' "$PVE_MEMBERS_FILE"
}

is_cluster_quorate() {
    perl -MJSON -0777 -e '
        my $j = from_json(<STDIN>);
        exit(defined($j->{cluster}->{quorate}) ? 0 : 1);
    ' "$PVE_MEMBERS_FILE"
}

local_ipv4_list() {
    ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true
}

preflight() {
    [[ $EUID -eq 0 ]] || fail "Run as root (sudo)."
    command -v pveversion >/dev/null || fail "Not a Proxmox VE host (pveversion missing)."
}

deploy_local() {
    install_plugin_file "$PLUGIN_URL"
}

# Run single-node deploy on a peer via SSH (script fetched from DEPLOY_SCRIPT_URL)
remote_deploy_via_curl() {
    local ip="$1"
    local url="$2"
    local rcmd
    rcmd=$(printf 'command -v curl >/dev/null || { echo "remote: need curl" >&2; exit 1; }; curl -fsSL %q | bash -s -- -u %q' \
        "$DEPLOY_SCRIPT_URL" "$url")
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${ip}" "$rcmd"
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -u|--url)
                PLUGIN_URL="${2:?}"
                shift 2
                ;;
            -a|--all-nodes)
                ALL_NODES=1
                shift
                ;;
            -n|--dry-run)
                DRY_RUN=1
                shift
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                fail "Unknown option: $1 (try --help)"
                ;;
        esac
    done

    [[ "$VERBOSE" -eq 1 ]] && set -x
    preflight

    if [[ "$ALL_NODES" -eq 0 ]]; then
        deploy_local
        log "Done."
        exit 0
    fi

    [[ -r "$PVE_MEMBERS_FILE" ]] || fail "Cannot read $PVE_MEMBERS_FILE"
    is_cluster || fail "Not in a cluster — run without --all-nodes"
    is_cluster_quorate || fail "Cluster is not quorate — refusing."

    mapfile -t node_ips < <(enumerate_cluster_nodes)
    [[ ${#node_ips[@]} -gt 0 ]] || fail "No nodes in $PVE_MEMBERS_FILE"

    mapfile -t local_ips < <(local_ipv4_list)

    local ip is_local
    for ip in "${node_ips[@]}"; do
        is_local=0
        local lip
        for lip in "${local_ips[@]}"; do
            [[ "$ip" == "$lip" ]] && { is_local=1; break; }
        done

        if [[ "$is_local" -eq 1 ]]; then
            log "=== Local node ($ip) ==="
            deploy_local
        else
            log "=== Remote node ($ip) ==="
            if [[ "$DRY_RUN" -eq 1 ]]; then
                log "DRY-RUN: would ssh root@$ip: curl $DEPLOY_SCRIPT_URL | bash -s -- -u <PLUGIN_URL>"
                continue
            fi
            remote_deploy_via_curl "$ip" "$PLUGIN_URL"
        fi
    done

    log "Done (all nodes)."
}

main "$@"
