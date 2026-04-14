# Release notes – v0.0.13

**Proxmox VE Plugin for HPE Nimble Storage (iSCSI)**

This plugin adds HPE Nimble Storage as a custom storage backend in Proxmox VE. It uses the Nimble REST API to create and manage volumes and presents them as VM disks over iSCSI, with optional multipath.

---

## What is new in v0.0.13

- **Snapshot rollback and volume online/offline** – The array requires the volume to be **offline** before `POST volumes/:id/actions/restore` (e.g. `SM_vol_not_offline_on_restore`). The plugin now ensures offline before restore, runs restore, then brings the volume back **online** with PUT retries and GET-after-PUT verification. Activate/deactivate paths do not force `online` in ways that mask array state. **`DELETE volumes/:id`** is always preceded by a best-effort offline attempt; failed create/clone cleanup uses the same helpers. **`nimble_ensure_initiator_group_id`** runs inside `eval` so orphan volumes are still removed when group resolution fails. On rollback, if restore and bring-online both fail, a warning is logged before the restore error is rethrown. New helpers: `nimble_volume_detail`, `nimble_volume_ensure_offline`, `nimble_volume_ensure_online`, `nimble_volume_offline_then_delete_best_effort`, with clearer volname labels in offline and snapshot-delete paths.

- **Runtime guards and import/export** – Stronger rollback preflight and safer error handling on import/export paths; release workflow **requires** unit tests and plugin syntax (bookworm + trixie) before building the `.deb`. New regression tests: `tests/unit/test_nimble_plugin_import_export_guards.t`.

- **CI** – Unit-test job installs the Perl modules the suite needs. Workflows opt into **Node.js 24** for JavaScript actions and use **actions/checkout@v5**.

- **Docs** – API validation and Nimble API reference updated for restore/offline flows; documentation index and README cross-links adjusted.

---

## Upgrading from v0.0.12

No storage config changes required. No manual migration steps needed.

Rollback to a snapshot should be more reliable on arrays that enforce offline-before-restore. If you hit restore errors, check plugin and syslog messages for offline/online and restore phases.

---

## Highlights (full product)

- **Full PVE storage integration** – Create, delete, resize, and rename Nimble volumes from the Proxmox UI or CLI. One LUN per VM disk; no manual LUN provisioning.
- **Snapshots and clones** – VM snapshots use array snapshots (create, delete, rollback). Array-created snapshots sync into PVE automatically. Clone from snapshot creates a new volume via the Nimble clone API.
- **Backup / restore disk images** – `raw+size` import and export; MiB-rounded allocation.
- **Automatic initiator and ACL** – Optional pre-created initiator group, or the plugin creates a group per node (`pve-<nodename>`) using the host IQN and grants access via access control records.
- **Auto iSCSI discovery (default on)** – Discovery IPs from subnets drive `iscsiadm` on storage activation unless `auto_iscsi_discovery` is `no`/`0`.
- **Live VM migration** – `multi_initiator=true` enables simultaneous iSCSI sessions from source and destination nodes.
- **Volume collections (protection plans)** – Optional `volume_collection` for array-side schedules.
- **Multipath** – By-id / WWN-aware discovery, multipathd add/remove, alias management, taint-safe external commands.
- **PVE 8 + PVE 9 support** – Tested on Debian bookworm (PVE 8) and trixie (PVE 9).

---

## Features at a glance

| Feature | Description |
|--------|-------------|
| **Volume lifecycle** | Create, delete, resize, rename volumes on the array via REST API |
| **ACL / initiator** | Optional `initiator_group` or auto `pve-<nodename>` with local IQN; access_control_records per volume |
| **Snapshots** | Create, delete, rollback; array-created snapshots sync to PVE automatically (v0.0.12+) |
| **Rollback offline/online** | Offline before restore, verified bring-online after (v0.0.13+) |
| **Clone from snapshot** | New volume from snapshot (POST volumes with clone=true); ACL + optional volume_collection |
| **Import / export** | `raw+size` format for disk backup/restore; MiB-rounded allocation; guarded error paths (v0.0.13+) |
| **Multipath** | By-id + WWID forms; multipathd add/remove; alias management with conf.d + WWID cache (v0.0.12+) |
| **Auto iSCSI discovery** | GET subnets + GET subnets/:id (authoritative portals); optional `iscsi_discovery_ips` |
| **Token cache** | Session token cached under `/etc/pve/priv/nimble/<storeid>.json` (cluster-safe) |
| **Live VM migration** | `multi_initiator=true` on all volumes; ACL + session ensured on destination before map |
| **list_images cache** | Volume list cached per PVE operation; no redundant REST calls (v0.0.12+) |
| **APIVER 12/13** | `volume_snapshot_info`, `volume_qemu_snapshot_method`, `qemu_blockdev_options` (v0.0.12+) |
| **APT upgrade** | postinst try-restarts core PVE services (v0.0.9+) |
| **PVE 8 + PVE 9** | bookworm and trixie APT dists; CI validates both |

---

## Requirements

- **Proxmox VE** 8.2+ (Debian bookworm) or 9.x (Debian trixie)
- **HPE Nimble** array with REST API enabled (default port 5392)
- **iSCSI** initiator on each node (`open-iscsi`) with IQN in `/etc/iscsi/initiatorname.iscsi`
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

- **APT – PVE 8 (bookworm):** `deb [...] https://brngates98.github.io/pve-nimble-plugin bookworm main`
- **APT – PVE 9 (trixie):** `deb [...] https://brngates98.github.io/pve-nimble-plugin trixie main`
- **Scripted install:** See [README – Option C](https://github.com/brngates98/pve-nimble-plugin#option-c-scripted-installer-single-node-or-all-cluster-nodes) for `install-pve-nimble-plugin.sh`.
- **Manual:** Download `libpve-storage-nimble-perl_0.0.13-1_all.deb` from Assets and run `apt install ./…deb` or `dpkg -i`.

**Important:** On a cluster, install the plugin on every node.

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
- **Version:** 0.0.13-1
- **Install path:** `NimbleStoragePlugin.pm` → `/usr/share/perl5/PVE/Storage/Custom/`
- **Maintainer scripts:** **postinst** restarts core PVE systemd units on **configure** (install/upgrade) when **`/run/systemd/system`** exists.

---

## Contributors and quality

- **CI:** Every push and pull request to `main` runs unit tests and `perl -c` against both Proxmox PVE 8 (bookworm) and PVE 9 (trixie) in Docker. Release builds require those jobs to pass before `dpkg-buildpackage`.
- **Local check:** `./scripts/verify_plugin_in_docker.sh` (bookworm) or `DIST=trixie ./scripts/verify_plugin_in_docker.sh` (trixie). Requires Docker.
