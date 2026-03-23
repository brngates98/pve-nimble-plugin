# Release notes – v0.0.10

**Proxmox VE Plugin for HPE Nimble Storage (iSCSI)**

This plugin adds HPE Nimble Storage as a custom storage backend in Proxmox VE. It uses the Nimble REST API to create and manage volumes and presents them as VM disks over iSCSI, with optional multipath.

---

## What is new in v0.0.10

This release is focused entirely on fixing **live VM migration** between Proxmox cluster nodes.

- **`multi_initiator=true` on all volumes** – The root cause of live migration failures. During live migration Proxmox requires both the source node (still running the VM) and the destination node to hold simultaneous iSCSI sessions to the same volume. Without `multi_initiator=true` the Nimble array restricts access to one initiator at a time and will not present the volume's IQN to a second host while the first host has an active session. New volumes and clones are now created with `multi_initiator=true`. A new helper (`nimble_ensure_volume_multi_initiator`) also PUTs this flag on **existing** volumes during every connect/activate, so volumes created before this release are automatically fixed on the next migration — no manual intervention required. The PUT is idempotent; failures produce a warning but do not block activation.

- **iSCSI session establishment rewritten on TrueNAS pattern** – `nimble_iscsi_establish_volume_session` is a clean rewrite modelled on TrueNAS `_iscsi_login_all`. The previous implementation accumulated `run_command` output lines via string concatenation (`$capture .= shift`) and then split on `\r?\n`. PVE's `run_command` calls `outfunc` once per line **without** a trailing newline, so string-concat + split silently collapsed all lines into one token — only the first portal was ever extracted on dual-controller arrays. The fix uses array accumulation (`push @lines, shift`), iterates `@lines` directly, and processes every portal independently. This matches TrueNAS `_run_lines` and is the canonical fix.

- **`nimble_iscsi_node_portals_for_target` regex corrected** – The function reads the node DB for a given IQN via `iscsiadm -m node --targetname <iqn>`, whose short-list output format is `10.1.1.1:3260,1 iqn.xxx`. The previous regex matched the `node.portal = ...` long-form format (wrong); updated to `m/^\s*(\S+)\s+iqn\./i` (correct short form). Without this fix, no portals were extracted from the node DB even after successful sendtargets discovery.

- **Session establishment moved to `nimble_volume_connection`** – Following the Pure Storage plugin pattern, ACL creation and iSCSI login are both done in the connect phase (`nimble_volume_connection`). `map_volume` then mirrors Pure: SCSI rescan + wait for device by serial. This eliminates double-login attempts and makes the lifecycle consistent with the reference plugin.

- **Login errors exposed** – `iscsiadm --login` stderr is now captured and surfaced as a `warn` (suppressing only "session already exists"). Previously all login failures were silently swallowed, making diagnosis impossible.

- **`iscsi_sendtargets_find_target` removed** – Intermediate function that parsed sendtargets output directly at the wrong layer and had the same string-concat outfunc bug. Removed entirely in the clean rewrite.

---

## Highlights (full product)

- **Full PVE storage integration** – Create, delete, resize, and rename Nimble volumes from the Proxmox UI or CLI. One LUN per VM disk; no manual LUN provisioning.
- **Snapshots and clones** – VM snapshots use array snapshots (create, delete, rollback). Clone from snapshot creates a new volume via the Nimble clone API and attaches ACL + optional volume collection.
- **Backup / restore disk images** – `raw+size` import and export (v0.0.8+); MiB-rounded allocation.
- **Automatic initiator and ACL** – Optional pre-created initiator group, or the plugin creates a group per node (`pve-<nodename>`) using the host IQN and grants access via access control records.
- **Auto iSCSI discovery (default on)** – Discovery IPs from subnets (and fallbacks) drive `iscsiadm` on storage activation unless `auto_iscsi_discovery` is `no`/`0`.
- **Volume collections (protection plans)** – Optional `volume_collection` for array-side schedules.
- **Multipath** – By-id / WWN-aware discovery, multipathd add/remove, taint-safe external commands.
- **Live VM migration** – `multi_initiator=true` ensures both source and destination nodes can hold concurrent iSCSI sessions; ACL is ensured for the destination's initiator group before login.

---

## Features at a glance

| Feature | Description |
|--------|-------------|
| **Volume lifecycle** | Create, delete, resize, rename volumes on the array via REST API |
| **ACL / initiator** | Optional `initiator_group` or auto `pve-<nodename>` with local IQN; access_control_records for each volume |
| **Snapshots** | Create, delete, rollback (in-place restore from snapshot) |
| **Clone from snapshot** | New volume from snapshot (POST volumes with clone=true); then ACL + optional volume_collection |
| **Import / export** | `raw+size` format for disk backup/restore (v0.0.8+); MiB-rounded allocation |
| **Multipath** | By-id + WWID forms; multipathd add/remove; safe under Perl `-T` |
| **Auto iSCSI discovery** | GET subnets + GET subnets/:id for every subnet (authoritative portals), then optional fallbacks, optional `iscsi_discovery_ips`, session IPs last |
| **Token cache** | Session token cached under `/etc/pve/priv/nimble/<storeid>.json` (cluster-safe) |
| **Live VM migration** | `multi_initiator=true` (new volumes + auto-fix existing); ACL + session ensured on destination before map |
| **APT upgrade** | postinst try-restarts core PVE services (v0.0.9+) |

---

## Requirements

- **Proxmox VE** 8.2+ (or compatible storage API)
- **HPE Nimble** array with REST API enabled (default port 5392)
- **iSCSI** initiator on each node (e.g. `open-iscsi`) with IQN in `/etc/iscsi/initiatorname.iscsi`
- (Optional) Existing Nimble initiator group name in `initiator_group`; otherwise the plugin creates one per node

---

## Configuration

Minimal storage config (plugin creates initiator group automatically):

```bash
pvesm add nimble <storage_id> --address https://<nimble>:5392 \
  --username <user> --password '<password>' --content images
```

With optional volume collection and auto iSCSI discovery:

```text
nimble: <storage_id>
  address https://<nimble>:5392
  username <user>
  password <pass>
  content images
  volume_collection pve-daily
  # auto_iscsi_discovery is on by default; add "auto_iscsi_discovery no" to disable
```

Other options: `initiator_group`, `pool_name`, `vnprefix`, `check_ssl`, `token_ttl`, `debug`, `iscsi_discovery_ips`. See the [README](https://github.com/brngates98/pve-nimble-plugin#configuration) for details.

---

## Installation

- **APT (Debian Bookworm):** Add the GitHub Pages APT repo (see [README – Option A](https://github.com/brngates98/pve-nimble-plugin#option-a-apt-repository-github-pages)) or install the `.deb` from the Assets below.
- **Scripted install:** See [README – Option C](https://github.com/brngates98/pve-nimble-plugin#option-c-scripted-installer-single-node-or-all-cluster-nodes) for `install-pve-nimble-plugin.sh`.
- **Manual:** Download `libpve-storage-nimble-perl_0.0.10-1_all.deb` from Assets and run `apt install ./…deb` or `dpkg -i`.

**Important:** On a cluster, install the plugin on every node.

---

## Upgrading from v0.0.9

No storage config changes are required.

**Live migration fix applies automatically to existing volumes.** On the first `activate_volume` or migration after upgrading, the plugin PUTs `multi_initiator=true` on the volume via the Nimble REST API. The operation is idempotent and non-fatal — if your Nimble firmware does not expose this field, a warning is logged and activation continues normally.

If you were previously working around live migration failures by taking VMs offline before migrating, you can stop doing that after this upgrade.

---

## Documentation

| Document | Description |
|----------|-------------|
| [README](https://github.com/brngates98/pve-nimble-plugin#readme) | Installation, configuration, migration, multipath, troubleshooting, scripted installer |
| [docs/00-SETUP-FULLY-PROTECTED-STORAGE.md](https://github.com/brngates98/pve-nimble-plugin/blob/main/docs/00-SETUP-FULLY-PROTECTED-STORAGE.md) | Step-by-step setup from zero to protected storage; restore workflow |
| [docs/API_VALIDATION.md](https://github.com/brngates98/pve-nimble-plugin/blob/main/docs/API_VALIDATION.md) | Nimble REST validation; Python SDK cross-check |
| [docs/NIMBLE_API_REFERENCE.md](https://github.com/brngates98/pve-nimble-plugin/blob/main/docs/NIMBLE_API_REFERENCE.md) | In-repo extract of HPE REST API 5.1.1.0 (endpoints, request/response) |
| [docs/STORAGE_FEATURES_COMPARISON.md](https://github.com/brngates98/pve-nimble-plugin/blob/main/docs/STORAGE_FEATURES_COMPARISON.md) | Feature comparison vs NFS, LVM, iSCSI, Ceph RBD |

---

## Package

- **Name:** `libpve-storage-nimble-perl`
- **Version:** 0.0.10-1
- **Install path:** `NimbleStoragePlugin.pm` → `/usr/share/perl5/PVE/Storage/Custom/`
- **Maintainer scripts:** **postinst** restarts core PVE systemd units on **configure** (install/upgrade) when **`/run/systemd/system`** exists.

---

## Contributors and quality

- **CI:** Push and pull requests to `main` run unit tests and a Docker-based `perl -c` check against Proxmox's `libpve-storage-perl` on Debian bookworm.
- **Local check:** `./scripts/verify_plugin_in_docker.sh` (requires Docker; uses your workspace copy, not a prebuilt `.deb`).
