# Release notes – v0.0.16

**Proxmox VE Plugin for HPE Nimble Storage (iSCSI)**

This plugin adds HPE Nimble Storage as a custom storage backend in Proxmox VE. It uses the Nimble REST API to create and manage volumes and presents them as VM disks (and LXC root volumes) over iSCSI, with optional multipath.

---

## What is new in v0.0.16

- **Array snapshot sync on “filter-only” firmware** – Some Nimble firmware returns **400** / **`SM_missing_arg`** for **`GET /v1/snapshots`** without **`vol_id`** (or another filter). **`nimble_sync_array_snapshots`** now tries an unfiltered list inside **`eval`**; on failure it merges **`GET snapshots?vol_id=`** for each PVE volume in the sync map, then runs the same cross-disk snapshot group logic. Restores array→PVE snapshot import on those arrays.

- **Access control records — `vol_id` vs `volume_id`** – List rows may expose **`volume_id`** instead of **`vol_id`**. New **`nimble_acr_vol_id`** is used when matching ACRs for **`nimble_volume_has_acl_for_ig`**, **`nimble_volume_connection`** (disconnect), and **`nimble_delete_access_control_records_for_volume_id`**.

- **`volume_snapshot_info`** – **`vol_id`** in **`GET snapshots?vol_id=`** is URI-escaped (consistent with other callers).

- **Offline when a cgroup sibling still has sessions** – **`nimble_volume_ensure_offline`** already retried with **`force: true`** on **409** / **`SM_vol_has_connections`**; related handling is aligned for sibling-volume / cgroup cases (see **`docs/API_VALIDATION.md`** snapshot rollback).

- **`scripts/nimble_api_unknowns_probe.sh`** – Optional live-array probe for “verify on array” checks: structured JSON report (default timestamped file), automatic probe volume id (**`GET volumes`** then **`GET access_control_records`**), **`SM_missing_arg`** detection for snapshots, ACR client counts using **`vol_id`** / **`volume_id`**. Prompts for URL / username / password (same style as **`nimble_capacity_api_probe.sh`**).

- **Docs** – **`docs/API_VALIDATION.md`**, **`docs/AI_PROJECT_CONTEXT.md`** updated for snapshots read requirements, sync behaviour, ACR fields, and the probe script.

---

## Upgrading from v0.0.15

- No **`storage.cfg`** changes. Replace the package on each node (`apt upgrade` from the GitHub Pages repo, or install the **`.deb`** from release Assets).
- If **array snapshot sync** never appeared to run (**`status()`** path) and your array rejects unfiltered **`GET snapshots`**, upgrade and confirm imported **`nimble<epoch>`** entries appear for array-side snapshots after a short delay.

---

## Highlights (full product)

- **Full PVE storage integration** – Create, delete, resize, and rename Nimble volumes from the Proxmox UI or CLI. One LUN per VM disk; no manual LUN provisioning.
- **LXC root on Nimble** – **`rootdir`** when **`content`** includes it; raw block only.
- **Snapshots and clones** – VM snapshots use array snapshots (create, delete, rollback). Array-created snapshots sync into PVE (**v0.0.16+**: per-volume snapshot GET when bulk list is rejected). Clone from snapshot uses the Nimble clone API.
- **Rollback** – Disconnect hosts before array offline; restore; bring volume **online** again (v0.0.15+).
- **Move disk / delete source** – Stronger Nimble teardown before volume **DELETE** (v0.0.15+).
- **Storage overview / capacity** – Pools hydrate, arrays fallback, **`pool_name`** (v0.0.14+).
- **APT upgrade** – **postinst** restarts **pvedaemon**, **pvestatd**, **pveproxy**, **pvescheduler** — not **pve-cluster** (v0.0.14+).
- **PVE 8 + PVE 9 support** – bookworm and trixie APT dists; CI validates both.

---

## Features at a glance

| Feature | Description |
|--------|-------------|
| **Volume lifecycle** | Create, delete, resize, rename volumes on the array via REST API |
| **LXC (`rootdir`)** | Optional; **`content`** includes **`rootdir`** (v0.0.14+) |
| **ACL / initiator** | Optional **`initiator_group`** or auto **`pve-<nodename>`**; **access_control_records** per volume |
| **Snapshots** | Create, delete, rollback; array sync with bulk or per-**`vol_id`** GET (v0.0.16+) |
| **Rollback** | Host disconnect + offline + restore + online (v0.0.15+) |
| **Move disk / delete source** | **`nimble_remove_volume`** disconnect + snapshot purge + **DELETE** retry (v0.0.15+) |
| **Clone from snapshot** | POST volumes **clone=true**; ACL + optional **volume_collection** |
| **Import / export** | **`raw+size`** |
| **Multipath** | By-id + WWID; multipathd add/remove; alias management |
| **Auto iSCSI discovery** | Subnets + optional **`iscsi_discovery_ips`** |
| **Token cache** | **`/etc/pve/priv/nimble/<storeid>.json`** |
| **Storage overview / capacity** | v0.0.14+ |
| **APT upgrade** | Four units, no **pve-cluster** (v0.0.14+) |
| **PVE 8 + PVE 9** | bookworm / trixie |

---

## Requirements

- **Proxmox VE** 8.2+ (Debian bookworm) or 9.x (Debian trixie)
- **HPE Nimble** array with REST API enabled (default port 5392)
- **iSCSI** initiator on each node (**`open-iscsi`**) with IQN in **`/etc/iscsi/initiatorname.iscsi`**
- (Optional) **`initiator_group`**; otherwise the plugin creates **`pve-<nodename>`** per node

---

## Configuration

```bash
pvesm add nimble <storage_id> --address https://<nimble>:5392 \
  --username <user> --password '<password>' --content images,rootdir
```

See the [README](https://github.com/brngates98/pve-nimble-plugin#configuration) for all options.

---

## Installation

- **APT – PVE 8 (bookworm):** `deb [...] https://brngates98.github.io/pve-nimble-plugin bookworm main`
- **APT – PVE 9 (trixie):** `deb [...] https://brngates98.github.io/pve-nimble-plugin trixie main`
- **Scripted install:** [README – Option C](https://github.com/brngates98/pve-nimble-plugin#option-c-scripted-installer-single-node-or-all-cluster-nodes)
- **Manual:** Download **`libpve-storage-nimble-perl_0.0.16-1_all.deb`** from Assets and run **`apt install ./…deb`** or **`dpkg -i`**.

**Important:** On a cluster, install the plugin on every node.

---

## Documentation

| Document | Description |
|----------|-------------|
| [README](https://github.com/brngates98/pve-nimble-plugin#readme) | Install, config, troubleshooting |
| [docs/API_VALIDATION.md](https://github.com/brngates98/pve-nimble-plugin/blob/main/docs/API_VALIDATION.md) | Plugin ↔ Nimble REST validation |
| [docs/NIMBLE_API_REFERENCE.md](https://github.com/brngates98/pve-nimble-plugin/blob/main/docs/NIMBLE_API_REFERENCE.md) | In-repo HPE REST API extract |
| [docs/AI_PROJECT_CONTEXT.md](https://github.com/brngates98/pve-nimble-plugin/blob/main/docs/AI_PROJECT_CONTEXT.md) | Maintainer / AI context |

---

## Package

- **Name:** `libpve-storage-nimble-perl`
- **Version:** 0.0.16-1
- **Install path:** `NimbleStoragePlugin.pm` → `/usr/share/perl5/PVE/Storage/Custom/`
- **Maintainer scripts:** **postinst** **try-restarts** **pvedaemon**, **pvestatd**, **pveproxy**, **pvescheduler** when **`/run/systemd/system`** exists (**no** **pve-cluster**).

---

## Contributors and quality

- **CI:** Unit tests and plugin syntax (bookworm + trixie) must pass before release **deb** build.
