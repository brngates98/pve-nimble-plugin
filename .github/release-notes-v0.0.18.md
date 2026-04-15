# Release notes – v0.0.18

**Proxmox VE Plugin for HPE Nimble Storage (iSCSI)**

This plugin adds HPE Nimble Storage as a custom storage backend in Proxmox VE. It uses the Nimble REST API to create and manage volumes and presents them as VM disks (and LXC root volumes) over iSCSI, with optional multipath.

---

## What is new in v0.0.18

- **Snapshot creation time in PVE after array sync** – On some firmware, **`GET snapshots?vol_id=`** list rows omit **`creation_time`** / **`last_modified`**, while **`GET snapshots/{id}`** (path) returns them. Earlier hydration merged responses with a flat hash assignment, so a follow-up **`GET snapshots?id=`** body with JSON **`null`** could overwrite good fields. This release merges detail rows with **`nimble_merge_snapshot_hash_skip_undef`**, extracts **`data`** as either an object or a single-element array (**`nimble_snapshot_detail_data_row`**), and wraps detail GETs in **`eval`** so a 404 on **`GET volumes/{id}`** does not abort sync.

- **Snapshot names with embedded schedule timestamps** – **`nimble_epoch_from_snapshot_name`** also parses volume-collection / schedule style names ending in **`-YYYY-MM-DD::HH:MM:SS[.fff]`** (in addition to existing **`NSs-…`** patterns) when the API never returns a time on the list row.

- **Diagnostic script** – **`scripts/nimble_snapshot_sync_diagnostic.sh`** adds **`simulated_plugin_merge_after_hydration`** in **`snapshot_time_detail_probe`**, matching the plugin merge order so you can confirm expected **`creation_time`** without installing Perl on the array host beyond **curl**/**jq**.

---

## Upgrading from v0.0.17

- No **`storage.cfg`** changes. Replace the package on each node (`apt upgrade` from the GitHub Pages repo, or install the **`.deb`** from release Assets).
- If snapshot times stayed blank in the UI while diagnostics showed **`GET snapshots/{id}`** with **`creation_time`**, upgrade to v0.0.18 and allow **pvestatd** / **`status()`** a cycle to re-sync.

---

## Highlights (full product)

- **Full PVE storage integration** – Create, delete, resize, and rename Nimble volumes from the Proxmox UI or CLI. One LUN per VM disk; no manual LUN provisioning.
- **LXC root on Nimble** – **`rootdir`** when **`content`** includes it; raw block only.
- **Snapshots and clones** – VM snapshots use array snapshots (create, delete, rollback). Array-created snapshots sync into PVE; **v0.0.18+** hydrates display time from **`GET snapshots/{id}`** when list rows omit times. Clone from snapshot uses the Nimble clone API.
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
| **Snapshots** | Create, delete, rollback; array sync with sparse rows (v0.0.17+) and detail hydration for snap time (v0.0.18+) |
| **Rollback** | Host disconnect + offline + restore + online (v0.0.15+) |
| **Move disk / delete source** | **`nimble_remove_volume`** disconnect + snapshot purge + **DELETE** retry (v0.0.15+) |
| **Clone from snapshot** | POST volumes **clone=true**; ACL + optional **`volume_collection`** |
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
- **Manual:** Download **`libpve-storage-nimble-perl_0.0.18-1_all.deb`** from Assets and run **`apt install ./…deb`** or **`dpkg -i`**.

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
- **Version:** 0.0.18-1
- **Install path:** `NimbleStoragePlugin.pm` → `/usr/share/perl5/PVE/Storage/Custom/`
- **Maintainer scripts:** **postinst** **try-restarts** **pvedaemon**, **pvestatd**, **pveproxy**, **pvescheduler** when **`/run/systemd/system`** exists (**no** **pve-cluster**).

---

## Contributors and quality

- **CI:** Unit tests and plugin syntax (bookworm + trixie) must pass before release **deb** build.
