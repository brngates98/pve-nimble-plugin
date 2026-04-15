# Release notes – v0.0.19

**Proxmox VE Plugin for HPE Nimble Storage (iSCSI)**

This plugin adds HPE Nimble Storage as a custom storage backend in Proxmox VE. It uses the Nimble REST API to create and manage volumes and presents them as VM disks (and LXC root volumes) over iSCSI, with optional multipath.

---

## What is new in v0.0.19

- **Array-import snapshot description** – When **`nimble_sync_array_snapshots`** adds **`nimble<epoch>`** snapshots to the VM config, the PVE **`description`** is the Nimble snapshot **`name`**, prefixed by the Nimble **volume name** for each disk: **`volume: snapshot name`** (each disk on the array). Multiple disks in one synced group are joined with **`; `** (deduped when identical). No generic “imported” text—only array-side strings.

---

## Upgrading from v0.0.18

- No **`storage.cfg`** changes. Replace the package on each node (`apt upgrade` from the GitHub Pages repo, or install the **`.deb`** from release Assets).
- New or re-imported array snapshots get the updated description format after sync; existing **`nimble*`** snapshot stanzas are unchanged unless removed and re-synced.

---

## Highlights (full product)

- **Full PVE storage integration** – Create, delete, resize, and rename Nimble volumes from the Proxmox UI or CLI. One LUN per VM disk; no manual LUN provisioning.
- **LXC root on Nimble** – **`rootdir`** when **`content`** includes it; raw block only.
- **Snapshots and clones** – VM snapshots use array snapshots (create, delete, rollback). Array-created snapshots sync into PVE with hydrated snap time (v0.0.18+) and **v0.0.19+** descriptions showing **`volume: Nimble snapshot name`**. Clone from snapshot uses the Nimble clone API.
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
| **Snapshots** | Create, delete, rollback; array sync (v0.0.17+), time hydration (v0.0.18+), import **`description`** **`volume: name`** (v0.0.19+) |
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
- **Manual:** Download **`libpve-storage-nimble-perl_0.0.19-1_all.deb`** from Assets and run **`apt install ./…deb`** or **`dpkg -i`**.

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
- **Version:** 0.0.19-1
- **Install path:** `NimbleStoragePlugin.pm` → `/usr/share/perl5/PVE/Storage/Custom/`
- **Maintainer scripts:** **postinst** **try-restarts** **pvedaemon**, **pvestatd**, **pveproxy**, **pvescheduler** when **`/run/systemd/system`** exists (**no** **pve-cluster**).

---

## Contributors and quality

- **CI:** Unit tests and plugin syntax (bookworm + trixie) must pass before release **deb** build.
