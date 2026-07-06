# Release notes – v0.0.23

**Proxmox VE Plugin for HPE Nimble Storage (iSCSI)**

This plugin adds HPE Nimble Storage as a custom storage backend in Proxmox VE. It uses the Nimble REST API to create and manage volumes and presents them as VM disks (and LXC root volumes) over iSCSI, with optional multipath.

---

## What is new in v0.0.23

This release focuses on **cluster safety** — making sure the plugin's iSCSI and multipath housekeeping can never step on other storage (another Nimble storage, `pve-purestorage-plugin`, or manually managed targets) sharing the same host, plus a round of iSCSI/multipath reliability fixes.

- **Scoped iSCSI auto-discovery/login** – Auto iSCSI discovery (`activate_storage`, and the throttled refresh from `status()`) used to log in on *every* record in the host's shared `iscsiadm` node database. It now logs in only on the `(portal, iqn)` records the array's own `sendtargets` call just reported — never touching targets that belong to other storage plugins or are manually managed.

- **`multipathd reconfigure` no longer fires on every VM start/stop** – Multipath alias register/deregister previously ran a full daemon reconfigure (which re-checks every multipath map on the host, not just this plugin's) unconditionally on every `map_volume`/`free_image`. It now skips the write + reconfigure whenever the WWID entry is already correct (or already absent), so a reconfigure only happens when the alias set actually changes.

- **Locked the cluster-shared WWID cache** – `/etc/pve/priv/nimble/<storeid>.wwid.json` lives on pmxcfs and is replicated to every cluster node. Register/deregister now wrap their read-modify-write in `PVE::Cluster::cfs_lock_storage` (pmxcfs's own distributed lock) so two nodes mapping/unmapping different volumes on the same storage at the same time can no longer silently drop each other's cache entry.

- **Multipath iSCSI login reliability** – Per-portal session checks ensure *all* multipath data paths stay logged in (Pure-style baseline on activate and the throttled `status()` refresh), instead of only confirming one path was up.

- **Volume used-bytes reporting fix** – Nimble's `vol_usage_compressed_bytes` is already in bytes; it was being scaled the same way as `size` (MB), inflating the "used" value shown for VM disks. Now used as-is.

- **iSCSI login noise reduction** – Skip per-target `iscsiadm` login when a session already exists, replacing a global `node --login` on activate that produced noisy (but benign) errors in the task log.

- **RAM snapshot (vmstate) path fix** – `nimble_resolve_block_path_for_volname` now activates the volume when `path()` runs before the LUN is mapped, fixing vmstate resolution for RAM snapshots.

- **`port` is now a real configurable property** – Previously read internally (`nimble_base_url`) but not declared in `properties()`/`options()`, so it was unreachable via `pvesm`/the UI. Non-standard management ports can now be set with `--port`.

- **Deterministic snapshot-group seeding** – `nimble_sync_array_snapshots` no longer depends on Perl hash key ordering to pick the volume that seeds a snapshot group; selection is now sorted and stable across repeated `status()` calls.

- **`debian/postrm` restart fix** – Corrected a maintainer-script condition that checked for an argument (`configure`) postrm is never actually invoked with, so the post-removal PVE daemon restart now runs.

- **Contributor tooling** – Added `AGENTS.md` with Cursor Cloud development instructions.

---

## Upgrading from v0.0.22

- No `storage.cfg` changes required. Existing storages keep working as-is; `port` is optional and only needed for non-standard management ports.
- Upgrade the package on each cluster node (`apt upgrade` from the GitHub Pages repo, or install the `.deb` from release Assets).
- After upgrade, restart is handled by **postinst** (`pvedaemon`, `pvestatd`, `pveproxy`, `pvescheduler`) when installing the `.deb`.
- If you're on a cluster where multiple nodes activate the same Nimble storage concurrently, this release directly reduces the chance of multipath alias drift between nodes — no action needed, it's automatic.

---

## Highlights (full product)

- **Full PVE storage integration** – Create, delete, resize, and rename Nimble volumes from the Proxmox UI or CLI. One LUN per VM disk; no manual LUN provisioning.
- **LXC root on Nimble** – `rootdir` when `content` includes it; raw block only.
- **Snapshots and clones** – VM snapshots use array snapshots (create, delete, rollback). Array-created snapshots sync into PVE with hydrated snap time, `volume: name` descriptions, and reliable rollback for `nimble*` keys. Clone from snapshot uses the Nimble clone API.
- **Cluster-safe multipath/iSCSI housekeeping** – Scoped discovery/login, change-gated `multipathd reconfigure`, and a distributed lock on the shared WWID cache (**v0.0.23+**).
- **VM Disks Date** – Shows creation/modified time from the array when list rows need hydration (`ctime`, v0.0.21+).
- **Disk grow** – Array resize + iSCSI/multipath refresh on the task node (v0.0.22+).
- **PVE storage API 14** – `get_identity`, `virtual-size`, `volume_resize` snap guard (v0.0.22+).
- **Rollback** – Host disconnect + offline + restore + online; `nimble*` import keys aligned with `snaptime` and hydration.
- **Move disk / delete source** – Stronger Nimble teardown before volume `DELETE`; migration unmap path hardened.
- **Storage overview / capacity** – Pools hydrate, arrays fallback, `pool_name`.
- **APT upgrade** – postinst restarts `pvedaemon`, `pvestatd`, `pveproxy`, `pvescheduler` — not `pve-cluster`.
- **PVE 8 + PVE 9 support** – bookworm and trixie APT dists; CI validates both.

---

## Features at a glance

| Feature | Description |
|--------|-------------|
| **Volume lifecycle** | Create, delete, resize, rename volumes on the array via REST API |
| **Disk grow** | Nimble **PUT** + host iSCSI/multipath refresh + `blockdev` wait (v0.0.22+) |
| **LXC (`rootdir`)** | Optional; `content` includes `rootdir` |
| **ACL / initiator** | Optional `initiator_group` or auto `pve-<nodename>`; `access_control_records` per volume |
| **Snapshots** | Create, delete, rollback; array sync, hydration, import descriptions, UI dedupe for PVE `.snap-*` rows |
| **PVE API 14** | `get_identity`, `virtual-size`, `volume_resize` snap guard (v0.0.22+) |
| **VM Disks list** | Date / `ctime` from Nimble times with GET `volumes/:id` when needed |
| **Rollback** | Host disconnect + offline + restore + online; `nimble*` hydration + qemu `snaptime` fallback |
| **Clone from snapshot** | POST volumes `clone=true`; ACL + optional `volume_collection` |
| **Import / export** | `raw+size` |
| **Multipath** | By-id + WWID; multipathd add/remove; alias management; change-gated reconfigure (v0.0.23+) |
| **Auto iSCSI discovery** | Subnets + optional `iscsi_discovery_ips`; scoped to this array's own sendtargets records (v0.0.23+) |
| **Cluster-shared state** | WWID alias cache locked via `PVE::Cluster::cfs_lock_storage` (v0.0.23+) |
| **Token cache** | `/etc/pve/priv/nimble/<storeid>.json` |
| **Storage overview / capacity** | Pools + arrays fallback |
| **APT upgrade** | Four units, no `pve-cluster` |
| **PVE 8 + PVE 9** | bookworm / trixie |

---

## Requirements

- **Proxmox VE** 8.2+ (Debian bookworm) or 9.x (Debian trixie)
- **HPE Nimble** array with REST API enabled (default port 5392)
- **iSCSI** initiator on each node (`open-iscsi`) with IQN in `/etc/iscsi/initiatorname.iscsi`
- (Optional) `initiator_group`; otherwise the plugin creates `pve-<nodename>` per node

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
- **Manual:** Download `libpve-storage-nimble-perl_0.0.23-1_all.deb` from Assets and run `apt install ./…deb` or `dpkg -i`.

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
- **Version:** 0.0.23-1
- **Install path:** `NimbleStoragePlugin.pm` → `/usr/share/perl5/PVE/Storage/Custom/`
- **Maintainer scripts:** postinst try-restarts `pvedaemon`, `pvestatd`, `pveproxy`, `pvescheduler` when `/run/systemd/system` exists (no `pve-cluster`). postrm does the same on `remove`/`purge` (v0.0.23+ — previously a dead condition).

---

## Contributors and quality

- **CI:** Unit tests and plugin syntax (bookworm + trixie) must pass before release deb build.
