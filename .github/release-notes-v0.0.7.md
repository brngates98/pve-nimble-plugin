# Release notes – v0.0.7

**Proxmox VE Plugin for HPE Nimble Storage (iSCSI)**

This plugin adds HPE Nimble Storage as a custom storage backend in Proxmox VE. It uses the Nimble REST API to create and manage volumes and presents them as VM disks over iSCSI, with optional multipath. The design follows the same patterns as the [Pure Storage plugin](https://github.com/kolesa-team/pve-purestorage-plugin) for consistency and familiarity.

---

## Highlights

- **Full PVE storage integration** – Create, delete, resize, and rename Nimble volumes from the Proxmox UI or CLI. One LUN per VM disk; no manual LUN provisioning.
- **Snapshots and clones** – VM snapshots use array snapshots (create, delete, rollback). Clone from snapshot creates a new volume via the Nimble clone API and attaches ACL + optional volume collection.
- **Automatic initiator and ACL** – No need to pre-create an initiator group on the array. The plugin creates a group per node (`pve-<nodename>`) using the host IQN and grants access via access control records.
- **Optional auto iSCSI discovery** – With `auto_iscsi_discovery 1`, the plugin fetches discovery IPs from the Nimble subnets API and runs `iscsiadm` discovery and login when storage is activated.
- **Volume collections (protection plans)** – Optional `volume_collection` setting: new volumes and clones are added to that Nimble volume collection so array-side protection/snapshot schedules apply.
- **Multipath** – Same pattern as the Pure plugin: device discovery by SCSI serial, multipathd add/remove, block device actions. Works after live migration.
- **Documentation and validation** – API usage validated against HPE Nimble REST API 5.1.1.0; docs aligned (API_VALIDATION, NIMBLE_API_REFERENCE, AI_PROJECT_CONTEXT). Snapshot/rollback/clone behavior aligned with Pure plugin.

---

## Features at a glance

| Feature | Description |
|--------|-------------|
| **Volume lifecycle** | Create, delete, resize, rename volumes on the array via REST API |
| **ACL / initiator** | Optional `initiator_group` or auto `pve-<nodename>` with local IQN; access_control_records for each volume |
| **Snapshots** | Create, delete, rollback (in-place restore from snapshot) |
| **Clone from snapshot** | New volume from snapshot (POST volumes with clone=true); then ACL + optional volume_collection |
| **Multipath** | Device by serial; multipathd add/remove; same pattern as Pure |
| **Auto iSCSI discovery** | Opt-in: GET subnets → discovery IPs → iscsiadm discovery + login on activate |
| **Token cache** | Session token cached under `/etc/pve/priv/nimble/<storeid>.json` (cluster-safe) |
| **VM migration** | Ensure-ACL on activate + serial-based device wait; works for live migration and move disk |

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
  auto_iscsi_discovery 1
```

Other options: `initiator_group`, `pool_name`, `vnprefix`, `check_ssl`, `token_ttl`, `debug`. See the [README](https://github.com/brngates98/pve-nimble-plugin#configuration) for details.

---

## Installation

- **APT (Debian Bookworm):** Add the GitHub Pages APT repo (see [README – Option A](https://github.com/brngates98/pve-nimble-plugin#option-a-apt-repository-github-pages)) or install the `.deb` from the Assets below.
- **Manual:** Download `libpve-storage-nimble-perl_0.0.7-1_all.deb` from Assets and install with `dpkg -i`.

**Important:** On a cluster, install the plugin on every node.

---

## Upgrading from v0.0.6

No config changes required. Existing storage continues to work. Optional:

- Set `volume_collection <name>` to add new volumes and clones to a Nimble volume collection.
- Set `auto_iscsi_discovery 1` to let the plugin run iSCSI discovery and login on storage activation.

---

## Documentation

| Document | Description |
|----------|-------------|
| [README](https://github.com/brngates98/pve-nimble-plugin#readme) | Installation, configuration, migration, multipath, troubleshooting |
| [docs/00-SETUP-FULLY-PROTECTED-STORAGE.md](https://github.com/brngates98/pve-nimble-plugin/blob/main/docs/00-SETUP-FULLY-PROTECTED-STORAGE.md) | Step-by-step setup from zero to protected storage; restore workflow |
| [docs/API_VALIDATION.md](https://github.com/brngates98/pve-nimble-plugin/blob/main/docs/API_VALIDATION.md) | Nimble REST API validation vs HPE docs; Pure plugin comparison |
| [docs/NIMBLE_API_REFERENCE.md](https://github.com/brngates98/pve-nimble-plugin/blob/main/docs/NIMBLE_API_REFERENCE.md) | In-repo extract of HPE REST API 5.1.1.0 (endpoints, request/response) |
| [docs/STORAGE_FEATURES_COMPARISON.md](https://github.com/brngates98/pve-nimble-plugin/blob/main/docs/STORAGE_FEATURES_COMPARISON.md) | Feature comparison vs NFS, LVM, iSCSI, Ceph RBD |

---

## Package

- **Name:** `libpve-storage-nimble-perl`
- **Version:** 0.0.7-1
- **Install path:** `NimbleStoragePlugin.pm` → `/usr/share/perl5/PVE/Storage/Custom/`

After installing or upgrading, restart `pvedaemon` and `pveproxy` if the plugin was loaded (or reboot the node).
