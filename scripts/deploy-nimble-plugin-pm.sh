#!/usr/bin/env bash
##############################################################################
# Install NimbleStoragePlugin.pm on Proxmox VE (one host, or whole cluster).
#
# ONLY EVER DOWNLOADS: NimbleStoragePlugin.pm (one Perl file). Nothing else.
# This .sh file is NOT copied and NOT curled to other nodes — keep it on one
# box if you like, or curl it once from GitHub; peers are reached via SSH and
# run a few lines that curl the same .pm URL, install it, restart services.
#
# Single host:
#   sudo bash scripts/deploy-nimble-plugin-pm.sh
#
# Every cluster node (you run this once on any node; others via SSH):
#   sudo bash scripts/deploy-nimble-plugin-pm.sh --all-nodes
#
# APT note: libpve-storage-nimble-perl upgrades can overwrite the .pm; prefer
# packages for production, use this for quick tests / hotfixes from git.
##############################################################################

set -euo pipefail

readonly TARGET='/usr/share/perl5/PVE/Storage/Custom/NimbleStoragePlugin.pm'
readonly PVE_MEMBERS_FILE='/etc/pve/.members'
# Same as scripts/install-pve-nimble-plugin.sh / debian/postinst
readonly RESTART_SERVICES=(pvedaemon pvestatd pveproxy pvescheduler)
readonly DEFAULT_PLUGIN_URL='https://raw.githubusercontent.com/brngates98/pve-nimble-plugin/main/NimbleStoragePlugin.pm'
PLUGIN_URL="${PLUGIN_URL:-$DEFAULT_PLUGIN_URL}"
DRY_RUN=0
ALL_NODES=0
VERBOSE=0

# Idempotent defaults for set -u / partial sourcing (e.g. snippet in a host upgrade script).
ensure_env() {
    PLUGIN_URL="${PLUGIN_URL:-$DEFAULT_PLUGIN_URL}"
    DRY_RUN="${DRY_RUN:-0}"
    ALL_NODES="${ALL_NODES:-0}"
    VERBOSE="${VERBOSE:-0}"
}

log() { printf '%b\n' "$*"; }
fail() { log "ERROR: $*"; exit 1; }

usage() {
    cat <<EOF
Usage: ${0##*/} [options]

  -u, --url URL     NimbleStoragePlugin.pm URL only (default: main on GitHub)
  -a, --all-nodes   Same .pm install on every node: local curl; remotes = SSH
                    then curl that .pm only (this script is never sent to peers)
  -n, --dry-run     Print actions only
  -v, --verbose     More output
  -h, --help        This help

Environment:
  PLUGIN_URL              Same as --url
  SSH_CONNECT_TIMEOUT     Seconds (default: 15); SSH to peers will not hang forever
  CURL_CONNECT_TIMEOUT    Seconds (default: 20)
  CURL_MAX_TIME           Max seconds per download (default: 120)
  DEPLOY_SSH_USE_IP       Set to 1 to SSH to root@<IP> instead of root@<nodename>
                          (IP is whatever /etc/pve/.members lists for that node; default is SSH by name)

  --all-nodes: SSH is root@<nodename> (pve001, pve002, …) from /etc/pve/.members — same names as
  Datacenter → Cluster. Passwordless root keys required (ssh-copy-id root@pve002, etc.).
  Local node: nodename matches /etc/hostname or hostname -s / short FQDN, else IP from .members on an iface.

Examples:
  curl -fsSL .../deploy-nimble-plugin-pm.sh | sudo bash    # get this helper once; it only pulls NimbleStoragePlugin.pm
  sudo PLUGIN_URL=https://.../NimbleStoragePlugin.pm bash deploy-nimble-plugin-pm.sh
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
    # Defaults avoid hanging forever when GitHub (or a mirror) is unreachable.
    local ct="${CURL_CONNECT_TIMEOUT:-20}"
    local mt="${CURL_MAX_TIME:-120}"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout "$ct" --max-time "$mt" -o "$out" -- "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout="$mt" -O "$out" -- "$url"
    else
        fail "Need curl or wget to download"
    fi
}

install_plugin_file() {
    local url="${1:-}"
    [[ -n "$url" ]] || fail "install_plugin_file: missing URL"
    local tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/nimble-plugin.XXXXXX")"
    # shellcheck disable=SC2064
    trap 'rm -f "$tmp"' RETURN

    log "Downloading: $url"
    download_to_file "$url" "$tmp"

    if ! head -n 1 "$tmp" | grep -q '^package PVE::Storage::Custom::NimbleStoragePlugin'; then
        fail "Download does not look like NimbleStoragePlugin.pm (missing expected package line)"
    fi

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log "DRY-RUN: would install to $TARGET and restart: ${RESTART_SERVICES[*]}"
        return
    fi

    install -d -m 755 "$(dirname "$TARGET")"
    install -m 644 "$tmp" "$TARGET"
    log "Installed: $TARGET"
    log "Restarting: ${RESTART_SERVICES[*]}"
    restart_pve_stack
}

# One line per node: nodename<TAB>ip (nodename matches "hostname -s" on that node for local detection).
enumerate_cluster_nodes() {
    perl -MJSON -0777 -e '
        my $j = from_json(<STDIN>);
        my $nl = $j->{nodelist} // {};
        for my $name (sort keys %$nl) {
            my $ent = $nl->{$name};
            next unless ref($ent) eq "HASH";
            my $ip = $ent->{ip} // next;
            print "$name\t$ip\n";
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
        my $c = $j->{cluster};
        exit( ($c && $c->{quorate}) ? 0 : 1 );
    ' "$PVE_MEMBERS_FILE"
}

local_ipv4_list() {
    ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true
}

# This host's cluster nodename from "pvecm status" (line with "(local)"). Most reliable for -a ordering.
pve_local_nodename() {
    command -v pvecm >/dev/null 2>&1 || return 0
    local out
    if command -v timeout >/dev/null 2>&1; then
        out=$(timeout 12 pvecm status 2>/dev/null) || out=""
    else
        out=$(pvecm status 2>/dev/null) || out=""
    fi
    echo "$out" | perl -lne 'print $1 if /\b(\S+)\s*\(local\)/' | head -1
}

preflight() {
    [[ $EUID -eq 0 ]] || fail "Run as root (sudo)."
    command -v pveversion >/dev/null || fail "Not a Proxmox VE host (pveversion missing)."
}

# Set DEPLOY_* vars in main before calling (all-nodes path).
node_row_is_local() {
    local nodename="$1"
    local ip="$2"
    [[ -n "${DEPLOY_PVE_LOCAL:-}" && "$nodename" == "${DEPLOY_PVE_LOCAL}" ]] && return 0
    [[ -n "${DEPLOY_HN_FILE:-}" && "$nodename" == "${DEPLOY_HN_FILE}" ]] && return 0
    [[ "$nodename" == "${DEPLOY_HN_SHORT:-}" || "$nodename" == "${DEPLOY_HN_FIRST:-}" \
        || "$nodename" == "${DEPLOY_HN_LONG:-}" || "$nodename" == "${DEPLOY_HOST_NOW:-}" ]] && return 0
    local lip
    for lip in "${DEPLOY_LOCAL_IPS[@]}"; do
        [[ "$ip" == "$lip" ]] && return 0
    done
    return 1
}

deploy_local() {
    ensure_env
    install_plugin_file "$PLUGIN_URL"
}

# Peer: SSH runs inline bash — curl NimbleStoragePlugin.pm, install, restart. No .sh file involved.
remote_deploy_via_ssh() {
    ensure_env
    local nodename="${1:-}"
    local ip="${2:-}"
    local url="${3:-}"
    [[ -n "$nodename" ]] || fail "remote_deploy_via_ssh: missing nodename"
    url="${url:-$PLUGIN_URL}"
    [[ -n "$url" ]] || fail "remote_deploy_via_ssh: missing plugin URL"
    local ct="${CURL_CONNECT_TIMEOUT:-20}"
    local mt="${CURL_MAX_TIME:-120}"
    local ssh_target
    if [[ "${DEPLOY_SSH_USE_IP:-0}" == "1" ]]; then
        [[ -n "$ip" ]] || fail "remote_deploy_via_ssh: DEPLOY_SSH_USE_IP=1 but missing IP for $nodename"
        ssh_target="${SSH_USER:-root}@${ip}"
        log "SSH $ssh_target (IP mode; member $nodename) timeout ${SSH_CONNECT_TIMEOUT:-15}s"
    else
        ssh_target="${SSH_USER:-root}@${nodename}"
        log "SSH $ssh_target (timeout ${SSH_CONNECT_TIMEOUT:-15}s) — member IP in .members: ${ip:-?}"
    fi
    ssh -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout="${SSH_CONNECT_TIMEOUT:-15}" \
        -o ConnectionAttempts=1 \
        "$ssh_target" \
        bash -s -- "$url" "$ct" "$mt" <<'REMOTE_SCRIPT'
set -euo pipefail
TARGET='/usr/share/perl5/PVE/Storage/Custom/NimbleStoragePlugin.pm'
SERVICES=(pvedaemon pvestatd pveproxy pvescheduler)
PLUGIN_URL_REMOTE=$1
CT=$2
MT=$3
command -v curl >/dev/null 2>&1 || { echo 'remote: install curl' >&2; exit 1; }
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
curl -fsSL --connect-timeout "$CT" --max-time "$MT" -o "$tmp" -- "$PLUGIN_URL_REMOTE"
head -n 1 "$tmp" | grep -q '^package PVE::Storage::Custom::NimbleStoragePlugin' \
  || { echo 'remote: file is not NimbleStoragePlugin.pm' >&2; exit 1; }
install -d -m 755 "$(dirname "$TARGET")"
install -m 644 "$tmp" "$TARGET"
if command -v deb-systemd-invoke >/dev/null 2>&1; then
  for s in "${SERVICES[@]}"; do deb-systemd-invoke try-restart "${s}.service" 2>/dev/null || true; done
else
  for s in "${SERVICES[@]}"; do systemctl try-restart "${s}.service" 2>/dev/null || true; done
fi
echo "remote: OK $TARGET"
REMOTE_SCRIPT
}

main() {
    ensure_env
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -u|--url)
                [[ $# -ge 2 && -n "${2-}" ]] || fail "Option $1 requires a non-empty URL"
                PLUGIN_URL="$2"
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

    [[ "${VERBOSE:-0}" -eq 1 ]] && set -x
    preflight

    if [[ "${ALL_NODES:-0}" -eq 0 ]]; then
        deploy_local
        log "Done."
        exit 0
    fi

    log "[all-nodes] preflight OK — entering cluster steps (if this hangs, check: pvecm status, ssh root@peers)."
    [[ -r "$PVE_MEMBERS_FILE" ]] || fail "Cannot read $PVE_MEMBERS_FILE"
    is_cluster || fail "Not in a cluster — run without --all-nodes"
    is_cluster_quorate || fail "Cluster is not quorate — refusing."

    log "[all-nodes] Reading nodelist from $PVE_MEMBERS_FILE ..."
    mapfile -t cluster_lines < <(enumerate_cluster_nodes)
    [[ ${#cluster_lines[@]} -gt 0 ]] || fail "No nodes in $PVE_MEMBERS_FILE"
    log "[all-nodes] Found ${#cluster_lines[@]} cluster member(s)."

    mapfile -t local_ips < <(local_ipv4_list)
    local hn_short hn_long hn_file hn_first host_now pve_local
    hn_short="$(hostname -s 2>/dev/null || hostname)"
    hn_long="$(hostname -f 2>/dev/null || hostname)"
    hn_first="${hn_long%%.*}"
    host_now="$(hostname 2>/dev/null || true)"
    hn_file=""
    if [[ -r /etc/hostname ]]; then
        IFS= read -r hn_file _ < /etc/hostname || true
        hn_file="${hn_file//$'\r'/}"
    fi
    log "[all-nodes] Resolving local nodename (pvecm) ..."
    pve_local="$(pve_local_nodename)"
    pve_local="${pve_local//$'\r'/}"
    log "[all-nodes] pvecm (local)='$pve_local'  hostname -s='$hn_short'  /etc/hostname='${hn_file:-}'"

    DEPLOY_PVE_LOCAL="$pve_local"
    DEPLOY_HN_FILE="$hn_file"
    DEPLOY_HN_SHORT="$hn_short"
    DEPLOY_HN_FIRST="$hn_first"
    DEPLOY_HN_LONG="$hn_long"
    DEPLOY_HOST_NOW="$host_now"
    DEPLOY_LOCAL_IPS=("${local_ips[@]}")

    local nodename ip did_local=0
    # 1) This host first (avoids alphabetical SSH to remotes while local still outdated / keys weird).
    log "[all-nodes] Step 1/2: this node (curl + install + restart) ..."
    for line in "${cluster_lines[@]}"; do
        IFS=$'\t' read -r nodename ip <<<"$line"
        [[ -n "${ip:-}" ]] || continue
        if node_row_is_local "$nodename" "$ip"; then
            log "=== LOCAL $nodename ($ip) ==="
            deploy_local
            did_local=1
            break
        fi
    done
    if [[ "$did_local" -eq 0 ]]; then
        log "WARNING: [all-nodes] could not match this host to a nodelist row (see pvecm/hostname above). Running install here anyway."
        deploy_local
    fi

    # 2) Peers via SSH
    log "[all-nodes] Step 2/2: remote nodes (SSH + curl .pm only) ..."
    for line in "${cluster_lines[@]}"; do
        IFS=$'\t' read -r nodename ip <<<"$line"
        [[ -n "${ip:-}" ]] || continue
        if node_row_is_local "$nodename" "$ip"; then
            continue
        fi
        log "=== REMOTE $nodename ($ip) ==="
        if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
            log "DRY-RUN: would ssh root@${nodename} (DEPLOY_SSH_USE_IP=1 → $ip)"
            continue
        fi
        remote_deploy_via_ssh "$nodename" "$ip" "$PLUGIN_URL"
    done

    log "Done (all nodes)."
}

main "$@"
