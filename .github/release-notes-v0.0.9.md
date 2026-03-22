# Release notes – v0.0.9

**Proxmox VE Plugin for HPE Nimble Storage (iSCSI)**

This plugin adds HPE Nimble Storage as a custom storage backend in Proxmox VE. It uses the Nimble REST API to create and manage volumes and presents them as VM disks over iSCSI, with optional multipath.

---

## What is new in v0.0.9

- **Package postinst: PVE services on `apt upgrade` / `dpkg --configure`** – The Debian **postinst** now uses **`deb-systemd-invoke try-restart`** when available (falls back to **`systemctl`**) and only runs under **`/run/systemd/system`**. On **install and upgrade**, it **try-restarts** `pve-cluster`, `pvedaemon`, `pvestatd`, `pveproxy`, and `pvescheduler` so the updated **`NimbleStoragePlugin.pm`** is loaded without a manual restart (Perl reads the module at daemon start).
- **Device path discovery (by-id / multipath)** – Resolves VM disks via **`/dev/disk/by-id`** first: deterministic **`wwn-0x<serial>`**, then any **by-id** name containing the API **`serial_number`**, then sysfs serial. Fixes timeouts when the active node is a **multipath `dm-*`** device without **`/sys/block/dm-*/device/serial`**.
- **Multipath WWID alignment** – Maps **`wwn-0x` + 32-hex NAA** to the **multipath** id form (**leading type nibble + 32 hex**, e.g. as in **`dm-uuid-mpath-…`** / **`scsi-2…`**). **`multipathd add/remove map`** and **`multipath -l`** try compatible id variants; **unmap** removes the **active** map id.
- **Perl taint mode (`-T`)** – **`pvedaemon`** runs custom storage plugins under taint checks. Device paths and WWIDs are **validated and untainted** before **`blockdev`**, **`multipathd`**, and related **`exec`** paths (fixes **“Insecure dependency in exec”** during volume deactivate).
- **iSCSI / discovery** – **`GET subnets/:id`** when the list is summary-only; prefer subnets whose **`type` contains `data`**; **`GET network_interfaces/:id`** when **`ip_list`** is missing; **live `iscsiadm` session IPs merged first**; **`node.startup=automatic`** per target+portal; **`iscsiadm -m session --rescan`**; longer **map** wait with periodic SCSI rescan; optional sendtargets/login **retry**.
- **`api()`** – Safer fallbacks if **`PVE::Storage::APIVER` / `APIAGE`** are unavailable.
- **Documentation** – README troubleshooting (duplicate **`properties`** keys, multipath WWID, taint); map/discovery notes; **`docs/API_VALIDATION`**, **`NIMBLE_API_REFERENCE`**, **`AI_PROJECT_CONTEXT`** updates.
- **Auto iSCSI discovery default on** – **`activate_storage`** runs subnet-based discovery and login unless **`auto_iscsi_discovery`** is **`no`** or **`0`**. Storages with no `auto_iscsi_discovery` line in **`storage.cfg`** are treated as **on** (same as new defaults).

---

## Highlights (full product)

- **Full PVE storage integration** – Create, delete, resize, and rename Nimble volumes from the Proxmox UI or CLI. One LUN per VM disk; no manual LUN provisioning.
- **Snapshots and clones** – VM snapshots use array snapshots (create, delete, rollback). Clone from snapshot creates a new volume via the Nimble clone API and attaches ACL + optional volume collection.
- **Backup / restore disk images** – `raw+size` import and export (v0.0.8+); MiB-rounded allocation.
- **Automatic initiator and ACL** – Optional pre-created initiator group, or the plugin creates a group per node (`pve-<nodename>`) using the host IQN and grants access via access control records.
- **Auto iSCSI discovery (default on)** – Discovery IPs from subnets (and fallbacks) drive `iscsiadm` on storage activation unless `auto_iscsi_discovery` is `no`/`0`.
- **Volume collections (protection plans)** – Optional `volume_collection` for array-side schedules.
- **Multipath** – By-id / WWN-aware discovery, multipathd add/remove, taint-safe external commands.

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
| **Auto iSCSI discovery** | Subnets (+ per-id), network interfaces (+ per-id), session IPs, optional `iscsi_discovery_ips` |
| **Token cache** | Session token cached under `/etc/pve/priv/nimble/<storeid>.json` (cluster-safe) |
| **VM migration** | Ensure-ACL on activate + robust device wait; works for live migration and move disk |
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
- **Manual:** Download `libpve-storage-nimble-perl_0.0.9-1_all.deb` from Assets and run `apt install ./…deb` or `dpkg -i`.

**Important:** On a cluster, install the plugin on every node.

---

## Upgrading from v0.0.8

No storage config changes are required. If an existing Nimble storage entry has **no** `auto_iscsi_discovery` line, **activate-time iSCSI discovery now runs** when the storage is activated; set **`auto_iscsi_discovery no`** (or **`0`**) on that storage if you want the previous “off unless set” behavior.

**v0.0.9+:** After **`apt upgrade`** or **`dpkg -i`**, the package **postinst** **try-restarts** `pve-cluster`, `pvedaemon`, `pvestatd`, `pveproxy`, and `pvescheduler` when systemd is active, so the new plugin file is picked up automatically. If a unit was stopped intentionally, **`try-restart`** leaves it stopped; start it manually if needed.

**Operational note:** This release focuses on **reliable VM disk map/unmap** with **multipath** and **Perl taint** on PVE 8.x.

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
- **Version:** 0.0.9-1
- **Install path:** `NimbleStoragePlugin.pm` → `/usr/share/perl5/PVE/Storage/Custom/`
- **Maintainer scripts:** **postinst** restarts core PVE systemd units on **configure** (install/upgrade) when **`/run/systemd/system`** exists.

---

## Contributors and quality

- **CI:** Push and pull requests to `main` run unit tests and a Docker-based `perl -c` check against Proxmox’s `libpve-storage-perl` on Debian bookworm.
- **Local check:** `./scripts/verify_plugin_in_docker.sh` (requires Docker; uses your workspace copy, not a prebuilt `.deb`).
