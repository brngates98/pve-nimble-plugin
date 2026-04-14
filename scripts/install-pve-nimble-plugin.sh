#!/usr/bin/env bash
##############################################################################
# PVE Nimble Storage Plugin Installer
# Copyright (c) pve-nimble-plugin contributors
#
# Validate supported PVE release, add APT repo (or install .deb from GitHub),
# and install libpve-storage-nimble-perl. Supports single-node and
# cluster-wide install (all nodes via SSH).
##############################################################################

##########################################################
# shell modes
##########################################################
set -o errtrace
set -o errexit

##########################################################
# exports
##########################################################
export http_proxy
export https_proxy
export all_proxy
export ftp_proxy
export no_proxy

##########################################################
# defines
##########################################################
readonly SCRIPT_VERSION="1.0"
readonly OS_RELEASE_FILE=/etc/os-release
readonly SOURCES_LIST=/etc/apt/sources.list.d/pve-nimble-plugin.list
# Same set/order as pve-purestorage-plugin debian/postinst (no pve-cluster); see debian/postinst in this repo.
readonly RESTARTED_SERVICES="pvedaemon pvestatd pveproxy pvescheduler"
readonly PVE_MEMBERS_FILE=/etc/pve/.members
readonly PACKAGE_NAME=libpve-storage-nimble-perl
readonly REPO_BASE="${REPO_BASE:-https://brngates98.github.io/pve-nimble-plugin}"
readonly GITHUB_RELEASES_BASE="${GITHUB_RELEASES_BASE:-https://github.com/brngates98/pve-nimble-plugin/releases/download}"

REPO_SUITE="${REPO_SUITE:-bookworm}"
REPO_SUITE_SET=0
REMOTE_NODE=

# avoid prompts from dpkg during package install
export DEBIAN_FRONTEND=noninteractive

##########################################################
# helpers
##########################################################
function log()
{
    if [ -z "$REMOTE_NODE" ]; then
        printf "%b\n" "$*"
    else
        printf "[REMOTE %s] %b\n" "$REMOTE_NODE" "$*"
    fi
}

function fail()
{
    log ""
    log "ERROR: $*"
    log ""
    exit 1
}

##########################################################
# usage
##########################################################
function usage()
{
    cat <<EOF
PVE Nimble Storage Plugin Installer $SCRIPT_VERSION

Options:
  -c, --codename SUITE          APT suite (default: bookworm)
  -V, --version X.Y.Z           Install specific release from GitHub (.deb) instead of APT repo
  -v, --verbose                 Enable verbose logging to stderr
  -l, --log-file FILE           Write installer logs to FILE
  -y, --yes                     Non-interactive mode; assume "yes" for confirmation
  -n, --dry-run                 Show what would be done; make no changes and skip prompts
  -a, --all-nodes               Install on all PVE cluster nodes via SSH
  -h, --help                    Show this help and exit

Single node:
  curl -fsSL https://raw.githubusercontent.com/brngates98/pve-nimble-plugin/main/scripts/install-pve-nimble-plugin.sh | sudo bash

All nodes (dry-run first):
  curl -fsSL ... | sudo bash -s -- --all-nodes --dry-run
  curl -fsSL ... | sudo bash -s -- --all-nodes
EOF
}

##########################################################
# issue
##########################################################
function issue()
{
    if [ -z "$REMOTE_NODE" ]; then
        log "PVE Nimble Storage Plugin Installer $SCRIPT_VERSION"
        log ""
    fi
}

##########################################################
# verify system is running a supported OS and version
##########################################################
function preflight()
{
    if [[ $EUID -ne 0 ]]; then
        fail "This script must be run as root. Please re-run with sudo or as root."
    fi

    builtin command -v pveversion >/dev/null || fail "This does not appear to be a Proxmox VE installation (pveversion command not found)"

    if [ ! -f "$OS_RELEASE_FILE" ]; then
        fail "Failed to determine OS release version ($OS_RELEASE_FILE not found)"
    fi

    source "$OS_RELEASE_FILE"

    OS_DIST=${ID-unset}
    if [ "$OS_DIST" == "unset" ]; then
        fail "Failed to determine OS distribution (ID not found in $OS_RELEASE_FILE)"
    fi

    if [ "${OS_DIST}" != "debian" ]; then
        fail "Unsupported OS distribution (expected 'debian' but found '${OS_DIST}')"
    fi

    OS_CODENAME=${VERSION_CODENAME-unset}
    if [ "$OS_CODENAME" == "unset" ]; then
        fail "Failed to determine distribution version (VERSION_CODENAME not found in $OS_RELEASE_FILE)"
    fi

    # Auto-select the correct APT suite from the OS codename unless the caller
    # explicitly passed --codename.
    if [[ "$REPO_SUITE_SET" -eq 0 ]]; then
        case "$OS_CODENAME" in
            trixie)  REPO_SUITE="trixie" ;;
            *)       REPO_SUITE="bookworm" ;;
        esac
    fi
}

# quote input for remote execution
function sh_quote()
{
    local s=${1-}
    printf "'%s'" "${s@Q}"
}

# Return a unique list of IPv4 addresses for all nodes in the cluster
function enumerate_cluster_nodes()
{
    if [[ ! -r "$PVE_MEMBERS_FILE" ]]; then
        fail "Unable to enumerate cluster nodes: $PVE_MEMBERS_FILE not readable"
    fi

    perl -l -MJSON -e '$/ = undef; my $j = from_json(<>); print(join "\n", map { $_->{ip} } values %{$j->{nodelist}});' "$PVE_MEMBERS_FILE"
}

# Return true if the current node is part of a cluster
function is_cluster()
{
    if [[ ! -r "$PVE_MEMBERS_FILE" ]]; then
        fail "Unable to enumerate cluster nodes: $PVE_MEMBERS_FILE not readable"
    fi

    perl -MJSON -e '$/ = undef; my $j = from_json(<>); exit(defined($j->{cluster}) ? 0 : 1);' \
        "$PVE_MEMBERS_FILE"
}

# Return true if the cluster is quorate
function is_cluster_quorate()
{
    if [[ ! -r "$PVE_MEMBERS_FILE" ]]; then
        fail "Unable to enumerate cluster nodes: $PVE_MEMBERS_FILE not readable"
    fi

    perl -MJSON -e '$/ = undef; my $j = from_json(<>); exit(defined($j->{cluster}->{quorate}) ? 0 : 1);' \
        "$PVE_MEMBERS_FILE"
}

# URL to fetch and run this installer remotely
function installer_url()
{
    local url="${INSTALLER_URL:-https://raw.githubusercontent.com/brngates98/pve-nimble-plugin/main/scripts/install-pve-nimble-plugin.sh}"
    echo "$url"
}

# Install plugin on all PVE nodes in the cluster (local + remotes via SSH)
function install_on_all_nodes()
{
    local -a local_ips
    local -a node_ips
    mapfile -t local_ips < <(ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)

    if is_cluster; then
        if ! is_cluster_quorate; then
            fail "Cluster does not have quorum -- refusing to proceed."
        fi

        mapfile -t node_ips < <(enumerate_cluster_nodes)
        if [[ ${#node_ips[@]} -eq 0 ]]; then
            fail "No cluster nodes found in $PVE_MEMBERS_FILE"
        fi

        log "Installing on ${#node_ips[@]} node PVE cluster."
    else
        log "Installing on local node -- non-cluster deployment detected."
        log ""
        install_software
        return
    fi

    local -a rflags=()
    [[ -n "$REPO_SUITE" ]] && rflags+=(--codename "$REPO_SUITE")
    [[ -n "$INSTALL_VERSION" ]] && rflags+=(--version "$INSTALL_VERSION")
    [[ "$VERBOSE" -eq 1 ]] && rflags+=(--verbose)
    [[ "$YES" -eq 1 ]] && rflags+=(--yes)
    [[ "$DRY_RUN" -eq 1 ]] && rflags+=(--dry-run)
    [[ "$LOG_FILE_SET" -eq 1 ]] && rflags+=(--log-file "$LOG_FILE")

    local export_cmds=""
    local v val
    for v in http_proxy https_proxy all_proxy ftp_proxy no_proxy; do
        val="${!v}"
        if [[ -n "$val" ]]; then
            export_cmds+="export $v=$(sh_quote "$val"); "
        fi
    done

    local inst_url
    inst_url="$(installer_url)"

    local ip
    for ip in "${node_ips[@]}"; do
        local is_local=0
        local lip
        for lip in "${local_ips[@]}"; do
            if [[ "$ip" == "$lip" ]]; then
                is_local=1
                break
            fi
        done

        if [[ $is_local -eq 1 ]]; then
            if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
                log ""
                log "DRY-RUN: would install on local node ($ip)..."
            else
                log ""
                log "Installing on local node ($ip)..."
            fi
            install_software
        else
            local remote_cmd
            remote_cmd=$(printf '/usr/bin/curl -fsSL %s | bash -s -- -X %s %s' "$(installer_url)" "$ip" "${rflags[*]}")
            remote_cmd=$(sh_quote "$remote_cmd")
            log ""
            log "Installing on remote node ($ip)..."
            builtin command /usr/bin/ssh "root@${ip}" "$remote_cmd"
        fi
    done
}

###########################################################################
# check_existing_install: detect whether this is a fresh install, an
# upgrade with the correct repo already in place, or an upgrade that
# requires the sources list to be updated first.
#
# Outputs one of: fresh | upgrade | repo_update
###########################################################################
function check_existing_install()
{
    local pkg_status
    pkg_status=$(dpkg-query -W -f='${Status}' "$PACKAGE_NAME" 2>/dev/null || true)
    if [[ "$pkg_status" != "install ok installed" ]]; then
        echo "fresh"
        return
    fi
    # Package is installed — check whether the sources list exists and
    # references the correct repo base URL and suite.
    if [[ -f "$SOURCES_LIST" ]] \
        && grep -qF "$REPO_BASE" "$SOURCES_LIST" \
        && grep -qF "$REPO_SUITE" "$SOURCES_LIST"; then
        echo "upgrade"
    else
        echo "repo_update"
    fi
}

###########################################################################
# install_software: add APT repo and install package, or install .deb from GitHub
###########################################################################
function install_software()
{
    if [[ "${YES:-0}" -ne 1 ]] && [[ "${DRY_RUN:-0}" -ne 1 ]] && [[ -t 0 ]]; then
        read -r -p "Do you want to continue? (y/n): " choice
        if [[ "$choice" != "y" ]]; then
            log "Installation aborted."
            exit 1
        fi
    fi

    if [[ -n "$INSTALL_VERSION" ]]; then
        install_from_github_deb
    else
        local mode
        mode=$(check_existing_install)
        case "$mode" in
            fresh)
                log "Fresh install — suite: $REPO_SUITE"
                ;;
            upgrade)
                log "$PACKAGE_NAME already installed. APT repo is correct (suite: $REPO_SUITE) — checking for upgrade."
                ;;
            repo_update)
                log "$PACKAGE_NAME already installed. APT repo needs updating to suite '$REPO_SUITE'."
                ;;
        esac
        install_from_apt_repo "$mode"
    fi
}

function install_from_apt_repo()
{
    local mode="${1:-fresh}"
    local step=1

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        case "$mode" in
            fresh)
                log "DRY-RUN: would write APT repo: deb [trusted=yes] $REPO_BASE $REPO_SUITE main -> $SOURCES_LIST"
                ;;
            repo_update)
                log "DRY-RUN: would update $SOURCES_LIST to: deb [trusted=yes] $REPO_BASE $REPO_SUITE main"
                ;;
            upgrade)
                log "DRY-RUN: APT repo already correct ($SOURCES_LIST, suite: $REPO_SUITE) — no change needed"
                ;;
        esac
        log "DRY-RUN: would update package lists: apt-get update -q"
        if [[ "$mode" == "fresh" ]]; then
            log "DRY-RUN: would install: apt-get install -y -q open-iscsi $PACKAGE_NAME"
        else
            log "DRY-RUN: would upgrade: apt-get install -y -q --only-upgrade $PACKAGE_NAME"
        fi
        log "DRY-RUN: would restart PVE services: systemctl try-reload-or-restart $RESTARTED_SERVICES"
        return
    fi

    case "$mode" in
        fresh)
            log "$((step++)). Adding PVE Nimble Plugin APT repository (suite: $REPO_SUITE)..."
            printf "deb [trusted=yes] %s %s main\n" "$REPO_BASE" "$REPO_SUITE" > "$SOURCES_LIST"
            chmod 644 "$SOURCES_LIST"
            ;;
        repo_update)
            log "$((step++)). Updating APT repository to suite '$REPO_SUITE'..."
            printf "deb [trusted=yes] %s %s main\n" "$REPO_BASE" "$REPO_SUITE" > "$SOURCES_LIST"
            chmod 644 "$SOURCES_LIST"
            ;;
        upgrade)
            log "$((step++)). APT repository already correct (suite: $REPO_SUITE)."
            ;;
    esac

    log "$((step++)). Updating package lists..."
    builtin command apt-get update -q >> "$LOG_FILE" 2>&1

    if [[ "$mode" == "fresh" ]]; then
        log "$((step++)). Installing open-iscsi and $PACKAGE_NAME..."
        builtin command apt-get install -y -q open-iscsi "$PACKAGE_NAME" >> "$LOG_FILE" 2>&1
    else
        log "$((step++)). Upgrading $PACKAGE_NAME..."
        builtin command apt-get install -y -q --only-upgrade "$PACKAGE_NAME" >> "$LOG_FILE" 2>&1
    fi

    log "$((step++)). Restarting PVE services ($RESTARTED_SERVICES)..."
    builtin command systemctl try-reload-or-restart $RESTARTED_SERVICES
}

function install_from_github_deb()
{
    local ver="$INSTALL_VERSION"
    local deb_name="${PACKAGE_NAME}_${ver}-1_all.deb"
    local deb_url="${GITHUB_RELEASES_BASE}/v${ver}/${deb_name}"
    local deb_tmp
    deb_tmp=$(mktemp -t "pve-nimble-plugin-${deb_name}.XXXXXX")

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log "DRY-RUN: would install open-iscsi: apt-get install -y -q open-iscsi"
        log "DRY-RUN: would download $deb_url"
        log "DRY-RUN: would install: dpkg -i $deb_name && apt-get install -f -y"
        log "DRY-RUN: would restart PVE services: systemctl try-reload-or-restart $RESTARTED_SERVICES"
        return
    fi

    log "1. Installing open-iscsi..."
    builtin command apt-get install -y -q open-iscsi >> "$LOG_FILE" 2>&1

    log "2. Downloading $deb_name from GitHub releases..."
    if ! builtin command /usr/bin/curl -fsSL -o "$deb_tmp" "$deb_url"; then
        rm -f "$deb_tmp"
        fail "Failed to download $deb_url (check version and network)"
    fi

    log "3. Installing $PACKAGE_NAME..."
    if ! dpkg -i "$deb_tmp"; then
        apt-get install -f -y -q >> "$LOG_FILE" 2>&1 || true
    fi
    rm -f "$deb_tmp"

    log "4. Restarting PVE services ($RESTARTED_SERVICES)..."
    builtin command systemctl try-reload-or-restart $RESTARTED_SERVICES
}

##########################################################
# post_install
##########################################################
function post_install()
{
    if [ -z "$REMOTE_NODE" ]; then
        log ""
        if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
            log "PVE Nimble Storage Plugin dry run complete. No changes were made."
        else
            log "PVE Nimble Storage Plugin installation complete."
        fi
    fi
}

function prepare()
{
    LOG_FILE=/dev/null
    VERBOSE=0
    LOG_FILE_SET=0
    YES=0
    ALL_NODES=0
    DRY_RUN=0
    INSTALL_VERSION=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--codename)
                if [[ -z "${2-}" ]]; then
                    fail "Option $1 requires an argument"
                fi
                REPO_SUITE="$2"
                REPO_SUITE_SET=1
                shift 2
                ;;
            -V|--version)
                if [[ -z "${2-}" ]]; then
                    fail "Option $1 requires an argument"
                fi
                INSTALL_VERSION="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            -y|--yes)
                YES=1
                shift
                ;;
            -a|--all-nodes)
                ALL_NODES=1
                shift
                ;;
            -n|--dry-run)
                DRY_RUN=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -l|--log-file)
                if [[ -z "${2-}" ]]; then
                    fail "Option $1 requires an argument"
                fi
                LOG_FILE="$2"
                LOG_FILE_SET=1
                shift 2
                ;;
            --installer-url)
                if [[ -z "${2-}" ]]; then
                    fail "Option $1 requires an argument"
                fi
                INSTALLER_URL=$2
                shift 2
                ;;
            -X)
                if [[ -z "${2-}" ]]; then
                    fail "Option $1 requires an argument"
                fi
                REMOTE_NODE=$2
                shift 2
                ;;
            --)
                shift
                break
                ;;
            -*)
                fail "Unknown option: $1"
                ;;
            *)
                log "Ignoring positional argument: $1"
                shift
                ;;
        esac
    done

    if [[ "$VERBOSE" -eq 1 && "${LOG_FILE_SET}" -eq 0 ]]; then
        LOG_FILE=/dev/stderr
    fi
}

##########################################################
# Verify and install the PVE Nimble Storage Plugin
##########################################################
install_pve_plugin()
{
    prepare "$@"
    issue
    preflight
    if [[ "${ALL_NODES:-0}" -eq 1 ]]; then
        install_on_all_nodes
    else
        install_software
    fi
    post_install
}

##########################################################
# execute
##########################################################
install_pve_plugin "$@"
