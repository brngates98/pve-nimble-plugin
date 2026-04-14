# Release notes – v0.0.14

**Proxmox VE Plugin for HPE Nimble Storage (iSCSI)**

This plugin adds HPE Nimble Storage as a custom storage backend in Proxmox VE. It uses the Nimble REST API to create and manage volumes and presents them as VM disks (and LXC root volumes) over iSCSI, with optional multipath.

---

## What is new in v0.0.14

- **Storage capacity in the Datacenter UI** – **`status()`** no longer sums only **`capacity`** from **GET `v1/pools`** list rows (many arrays return **paged summaries** with **`id`/`name` only**). The plugin **GETs `v1/pools/:id`** when needed, derives totals from **`free_space` + `usage`** when **`capacity`** is missing, optionally scopes to **`pool_name`** (**`name` | `search_name` | `full_name` | array-style `pool_name`**), and falls back to **GET `v1/arrays`** when pool totals are still zero. Removes the old **“1 byte”** placeholder on success; API failure returns **`(0,0,0,0)`** (inactive). See **`docs/NIMBLE_API_REFERENCE.md` §9** for a known compression caveat when capacity is derived.

- **LXC (`rootdir`)** – **`plugindata`** advertises **`rootdir`** alongside **`images`** (and **`none`**). Raw block CT roots use the same **`vm-<id>-disk-*`** naming as VMs. Set **`--content images,rootdir`** (or narrow to **`images`** only if you do not want CT disks on that store). Array snapshot sync remains **QEMU VM configs only**; CT volumes are skipped there by design.

- **README / docs** – Feature comparison tables (vs NFS, LVM, iSCSI, RBD) in the README; **`CONTRIBUTING.md`** documentation maintenance and TOC stubs; probe script and status/capacity notes in **`docs/API_VALIDATION.md`**, **`docs/NIMBLE_API_REFERENCE.md`**, **`docs/AI_PROJECT_CONTEXT.md`**.

- **`scripts/nimble_capacity_api_probe.sh`** – Interactive **curl** + **jq** helper: login, **pools**, **pools/:id**, **arrays** → one JSON file (token redacted) for lab verification of API shapes.

- **Package postinst (APT upgrade)** – **Does not** **`try-restart` `pve-cluster`** (avoids long **corosync/quorum** stalls during **`apt upgrade`**). Restarts the same four units as [pve-purestorage-plugin `debian/postinst`](https://github.com/kolesa-team/pve-purestorage-plugin/blob/main/debian/postinst) **except** **`pve-cluster`**: **`pvedaemon`**, **`pvestatd`**, **`pveproxy`**, **`pvescheduler`**. Uses **`deb-systemd-invoke`** when available. **`install-pve-nimble-plugin.sh`** restarts the same four services.

---

## Upgrading from v0.0.13

- No required **`storage.cfg`** changes. Optional: add **`rootdir`** to **`content`** if you want LXC roots on Nimble:  
  `pvesm set <id> --content images,rootdir`
- After upgrade, **Datacenter → Storage** should show **real** total / used / free for Nimble (arrays that omit pool **capacity** on the list endpoint are handled).
- **APT** should complete without hanging on **`pve-cluster`** restart; if an older package postinst already ran, a one-time **`systemctl restart pvedaemon pvestatd pveproxy`** (or reinstall) picks up behavior.

---

## Highlights (full product)

- **Full PVE storage integration** – Create, delete, resize, and rename Nimble volumes from the Proxmox UI or CLI. One LUN per VM disk; no manual LUN provisioning.
- **LXC root on Nimble** – **`rootdir`** when **`content`** includes it; raw block only.
- **Snapshots and clones** – VM snapshots use array snapshots (create, delete, rollback). Array-created snapshots sync into PVE automatically. Clone from snapshot creates a new volume via the Nimble clone API.
- **Backup / restore disk images** – **`raw+size`** import and export; MiB-rounded allocation.
- **Automatic initiator and ACL** – Optional pre-created initiator group, or the plugin creates a group per node (**`pve-<nodename>`**) using the host IQN and grants access via access control records.
- **Auto iSCSI discovery (default on)** – Discovery IPs from subnets drive **`iscsiadm`** on storage activation unless **`auto_iscsi_discovery`** is **`no`**/**`0`**.
- **Live VM migration** – **`multi_initiator=true`** enables simultaneous iSCSI sessions from source and destination nodes.
- **Volume collections (protection plans)** – Optional **`volume_collection`** for array-side schedules.
- **Multipath** – By-id / WWN-aware discovery, multipathd add/remove, alias management, taint-safe external commands.
- **PVE 8 + PVE 9 support** – Tested on Debian bookworm (PVE 8) and trixie (PVE 9).

---

## Features at a glance

| Feature | Description |
|--------|-------------|
| **Volume lifecycle** | Create, delete, resize, rename volumes on the array via REST API |
| **LXC (`rootdir`)** | Optional; **`content`** must include **`rootdir`** (v0.0.14+) |
| **ACL / initiator** | Optional **`initiator_group`** or auto **`pve-<nodename>`** with local IQN; **access_control_records** per volume |
| **Snapshots** | Create, delete, rollback; array-created snapshots sync to PVE automatically |
| **Rollback offline/online** | Offline before restore, verified bring-online after (v0.0.13+) |
| **Clone from snapshot** | New volume from snapshot (POST volumes with **clone=true**); ACL + optional **volume_collection** |
| **Import / export** | **`raw+size`** format for disk backup/restore |
| **Multipath** | By-id + WWID forms; multipathd add/remove; alias management |
| **Auto iSCSI discovery** | GET subnets + GET subnets/:id; optional **`iscsi_discovery_ips`** |
| **Token cache** | Session token under **`/etc/pve/priv/nimble/<storeid>.json`** |
| **Storage overview / capacity** | Pools list hydrate, **arrays** fallback, **`pool_name`** filter (v0.0.14+) |
| **APT upgrade** | **postinst** restarts **pvedaemon**, **pvestatd**, **pveproxy**, **pvescheduler** — **not** **pve-cluster** (v0.0.14+) |
| **PVE 8 + PVE 9** | bookworm and trixie APT dists; CI validates both |

---

## Requirements

- **Proxmox VE** 8.2+ (Debian bookworm) or 9.x (Debian trixie)
- **HPE Nimble** array with REST API enabled (default port 5392)
- **iSCSI** initiator on each node (**`open-iscsi`**) with IQN in **`/etc/iscsi/initiatorname.iscsi`**
- (Optional) Existing Nimble initiator group name in **`initiator_group`**; otherwise the plugin creates one per node

---

## Configuration

```bash
pvesm add nimble <storage_id> --address https://<nimble>:5392 \
  --username <user> --password '<password>' --content images,rootdir
```

Use **`images`** only if you do not want LXC root disks on that store. Optional **`pool_name`** limits **status** capacity totals to that pool when the API returns multiple pools.

See the [README](https://github.com/brngates98/pve-nimble-plugin#configuration) for all options.

---

## Installation

- **APT – PVE 8 (bookworm):** `deb [...] https://brngates98.github.io/pve-nimble-plugin bookworm main`
- **APT – PVE 9 (trixie):** `deb [...] https://brngates98.github.io/pve-nimble-plugin trixie main`
- **Scripted install:** [README – Option C](https://github.com/brngates98/pve-nimble-plugin#option-c-scripted-installer-single-node-or-all-cluster-nodes)
- **Manual:** Download **`libpve-storage-nimble-perl_0.0.14-1_all.deb`** from Assets and run **`apt install ./…deb`** or **`dpkg -i`**.

**Important:** On a cluster, install the plugin on every node.

---

## Documentation

| Document | Description |
|----------|-------------|
| [README](https://github.com/brngates98/pve-nimble-plugin#readme) | Install, config, feature comparison tables, troubleshooting |
| [docs/00-SETUP-FULLY-PROTECTED-STORAGE.md](https://github.com/brngates98/pve-nimble-plugin/blob/main/docs/00-SETUP-FULLY-PROTECTED-STORAGE.md) | Full setup walkthrough |
| [docs/API_VALIDATION.md](https://github.com/brngates98/pve-nimble-plugin/blob/main/docs/API_VALIDATION.md) | Plugin ↔ Nimble REST validation |
| [docs/NIMBLE_API_REFERENCE.md](https://github.com/brngates98/pve-nimble-plugin/blob/main/docs/NIMBLE_API_REFERENCE.md) | In-repo HPE REST API extract |
| [docs/STORAGE_FEATURES_COMPARISON.md](https://github.com/brngates98/pve-nimble-plugin/blob/main/docs/STORAGE_FEATURES_COMPARISON.md) | vs NFS, LVM, iSCSI, RBD |

---

## Package

- **Name:** `libpve-storage-nimble-perl`
- **Version:** 0.0.14-1
- **Install path:** `NimbleStoragePlugin.pm` → `/usr/share/perl5/PVE/Storage/Custom/`
- **Maintainer scripts:** **postinst** **try-restarts** **pvedaemon**, **pvestatd**, **pveproxy**, **pvescheduler** when **`/run/systemd/system`** exists (**no** **pve-cluster**).

---

## Contributors and quality

- **CI:** Unit tests and plugin syntax (bookworm + trixie) must pass before release **deb** build.
- **Probe:** **`./scripts/nimble_capacity_api_probe.sh`** for optional API capture on a live array.
