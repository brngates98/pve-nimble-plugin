# Release notes – v0.0.22

**Proxmox VE Plugin for HPE Nimble Storage (iSCSI)**

This plugin adds HPE Nimble Storage as a custom storage backend in Proxmox VE. It uses the Nimble REST API to create and manage volumes and presents them as VM disks (and LXC root volumes) over iSCSI, with optional multipath.

---

## What is new in v0.0.22

- **PVE storage plugin API 14** – **`sub api`** reports **14** on hosts with **`PVE::Storage::APIVER()`** 14+ (still **13** on older PVE for backward compatibility). Silences the *“implementing an older storage API”* warning on API 14 installs.

- **`volume_resize`** – Accepts optional **`$snapname`** (API 14). Dies with a clear error when set — Nimble does not use **`snapshot-as-volume-chain`**. Normal disk grow is unchanged when **`$snapname`** is omitted.

- **`volume_snapshot_info`** – Returns **`virtual-size`** (bytes at snap time) from Nimble snapshot **`size`** (MB). **`nimble_hydrate_snapshot_detail`** runs when list rows omit **`size`** even if **`creation_time`** is present.

- **`get_identity`** (API 14) – Stable backend id **`nimble:<array id>`** from **GET `arrays`**, filtered by **`pool_name`** like **`status()`**, sorted by array **`id`**. Falls back to **`nimble:<address>`** when the arrays API is unavailable (different DNS names for the same array may differ until the API succeeds).

- **Disk grow (resize) host refresh** – After **`PUT volumes/:id`** with a larger **`size`**, **`nimble_host_refresh_volume_size_after_array_resize`** rescans iSCSI/multipath and waits for **`blockdev`** so PVE resize tasks do not fail while the array already shows the new size.

- **Unit tests** – **`tests/unit/test_storage_api_ver14.t`** covers **`api()`** fallbacks, **`virtual-size`**, **`volume_resize`** snap guard, hydration, and **`get_identity`**.

- **Documentation** – README screenshots and LXC notes; **`docs/API_VALIDATION.md`** and **`docs/AI_PROJECT_CONTEXT.md`** updated for API 14 and resize refresh.

---

## Upgrading from v0.0.21

- No **`storage.cfg`** changes. Upgrade the package on each cluster node (`apt upgrade` from the GitHub Pages repo, or install the **`.deb`** from release Assets).
- After upgrade, restart is handled by **postinst** (**`pvedaemon`**, **`pvestatd`**, **`pveproxy`**, **`pvescheduler`**) when installing the **`.deb`**.
- On PVE builds that still report storage **APIVER 13**, the plugin continues to report **13**; API 14 methods are additive and safe on those hosts.

---

## Highlights (full product)

- **Full PVE storage integration** – Create, delete, resize, and rename Nimble volumes from the Proxmox UI or CLI. One LUN per VM disk; no manual LUN provisioning.
- **LXC root on Nimble** – **`rootdir`** when **`content`** includes it; raw block only.
- **Snapshots and clones** – VM snapshots use array snapshots (create, delete, rollback). Array-created snapshots sync into PVE with hydrated snap time, **`volume: name`** descriptions, and reliable rollback for **`nimble*`** keys. Clone from snapshot uses the Nimble clone API.
- **VM Disks Date** – Shows creation/modified time from the array when list rows need hydration (**`ctime`**, v0.0.21+).
- **Disk grow** – Array resize + iSCSI/multipath refresh on the task node (**v0.0.22+**).
- **PVE storage API 14** – **`get_identity`**, **`virtual-size`**, **`volume_resize`** snap guard (**v0.0.22+**).
- **Rollback** – Host disconnect + offline + restore + online; **`nimble*`** import keys aligned with **`snaptime`** and hydration.
- **Move disk / delete source** – Stronger Nimble teardown before volume **DELETE**; migration unmap path hardened.
- **Storage overview / capacity** – Pools hydrate, arrays fallback, **`pool_name`**.
- **APT upgrade** – **postinst** restarts **pvedaemon**, **pvestatd**, **pveproxy**, **pvescheduler** — not **pve-cluster**.
- **PVE 8 + PVE 9 support** – bookworm and trixie APT dists; CI validates both.

---

## Features at a glance

| Feature | Description |
|--------|-------------|
| **Volume lifecycle** | Create, delete, resize, rename volumes on the array via REST API |
| **Disk grow** | Nimble **PUT** + host iSCSI/multipath refresh + **`blockdev`** wait (**v0.0.22+**) |
| **LXC (`rootdir`)** | Optional; **`content`** includes **`rootdir`** |
| **ACL / initiator** | Optional **`initiator_group`** or auto **`pve-<nodename>`**; **access_control_records** per volume |
| **Snapshots** | Create, delete, rollback; array sync, hydration, import descriptions, UI dedupe for PVE `.snap-*` rows |
| **PVE API 14** | **`get_identity`**, **`virtual-size`**, **`volume_resize`** snap guard (**v0.0.22+**) |
| **VM Disks list** | **Date** / **`ctime`** from Nimble times with **GET `volumes/:id`** when needed |
| **Rollback** | Host disconnect + offline + restore + online; **`nimble*`** hydration + qemu **`snaptime`** fallback |
| **Clone from snapshot** | POST volumes **clone=true**; ACL + optional **`volume_collection`** |
| **Import / export** | **`raw+size`** |
| **Multipath** | By-id + WWID; multipathd add/remove; alias management |
| **Auto iSCSI discovery** | Subnets + optional **`iscsi_discovery_ips`** |
| **Token cache** | **`/etc/pve/priv/nimble/<storeid>.json`** |
| **Storage overview / capacity** | Pools + arrays fallback |
| **APT upgrade** | Four units, no **pve-cluster** |
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
- **Manual:** Download **`libpve-storage-nimble-perl_0.0.22-1_all.deb`** from Assets and run **`apt install ./…deb`** or **`dpkg -i`**.

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
- **Version:** 0.0.22-1
- **Install path:** `NimbleStoragePlugin.pm` → `/usr/share/perl5/PVE/Storage/Custom/`
- **Maintainer scripts:** **postinst** **try-restarts** **pvedaemon**, **pvestatd**, **pveproxy**, **pvescheduler** when **`/run/systemd/system`** exists (**no** **pve-cluster**).

---

## Contributors and quality

- **CI:** Unit tests and plugin syntax (bookworm + trixie) must pass before release **deb** build.
