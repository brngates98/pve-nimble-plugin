# Release notes – v0.0.15

**Proxmox VE Plugin for HPE Nimble Storage (iSCSI)**

This plugin adds HPE Nimble Storage as a custom storage backend in Proxmox VE. It uses the Nimble REST API to create and manage volumes and presents them as VM disks (and LXC root volumes) over iSCSI, with optional multipath.

---

## What is new in v0.0.15

- **Snapshot rollback (`SM_vol_has_connections`)** – Nimble rejects **`PUT volumes/:id`** **`online=false`** while initiators are still connected. Before offlining for **`POST …/actions/restore`**, the plugin runs **`nimble_volume_prepare_restore_disconnect`**: **`unmap_volume`**, **`nimble_iscsi_logout_volume_local`** (per-portal **`iscsiadm --logout`** plus session fallback), and **DELETE all `access_control_records`** for the volume (all initiator groups). **`activate_volume`** after rollback re-posts ACL and maps the disk.

- **Move disk — delete source on Nimble (`free_image` / `nimble_remove_volume`)** – After a storage migration with **delete source** checked, the source volume could remain on the array (**409** / **`SM_eperm`** on volume **DELETE**). **`nimble_remove_volume`** now starts with the same **disconnect** prep as rollback, then **multipath** cleanup, ACR cleanup, **snapshot purge → offline → snapshot purge** (with **multi-round** snapshot **DELETE**, newest-first, **warnings** on failed snapshot deletes), then **DELETE** volume. On **409** / **`SM_http_conflict`** / **`SM_eperm`**, a **3 s** pause and a **second** full prep + **DELETE** are attempted.

- **Docs** – **`docs/API_VALIDATION.md`**, **`docs/NIMBLE_API_REFERENCE.md`**, **`docs/AI_PROJECT_CONTEXT.md`** updated for rollback prep, volume delete, and migration source removal.

---

## Upgrading from v0.0.14

- No **`storage.cfg`** changes. Replace the package on each node (`apt upgrade` from the GitHub Pages repo, or install the **`.deb`** from release Assets).
- Re-test **snapshot rollback** and **move disk with delete source** on a lab VM if you hit the previous errors.

---

## Highlights (full product)

- **Full PVE storage integration** – Create, delete, resize, and rename Nimble volumes from the Proxmox UI or CLI. One LUN per VM disk; no manual LUN provisioning.
- **LXC root on Nimble** – **`rootdir`** when **`content`** includes it; raw block only.
- **Snapshots and clones** – VM snapshots use array snapshots (create, delete, rollback). Array-created snapshots sync into PVE automatically. Clone from snapshot creates a new volume via the Nimble clone API.
- **Rollback** – Disconnect hosts before array offline; restore; bring volume **online** on the array again (v0.0.15+).
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
| **Snapshots** | Create, delete, rollback; array-created snapshots sync to PVE automatically |
| **Rollback** | Host disconnect + offline + restore + online (v0.0.15+ fixes **`SM_vol_has_connections`**) |
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
- **Manual:** Download **`libpve-storage-nimble-perl_0.0.15-1_all.deb`** from Assets and run **`apt install ./…deb`** or **`dpkg -i`**.

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
- **Version:** 0.0.15-1
- **Install path:** `NimbleStoragePlugin.pm` → `/usr/share/perl5/PVE/Storage/Custom/`
- **Maintainer scripts:** **postinst** **try-restarts** **pvedaemon**, **pvestatd**, **pveproxy**, **pvescheduler** when **`/run/systemd/system`** exists (**no** **pve-cluster**).

---

## Contributors and quality

- **CI:** Unit tests and plugin syntax (bookworm + trixie) must pass before release **deb** build.
