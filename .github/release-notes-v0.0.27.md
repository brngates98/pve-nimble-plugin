# Release notes – v0.0.27

**Proxmox VE Plugin for HPE Nimble Storage (iSCSI)**

This plugin adds HPE Nimble Storage as a custom storage backend in Proxmox VE. It uses the Nimble REST API to create and manage volumes and presents them as VM disks (and LXC root volumes) over iSCSI, with optional multipath.

---

## What is new in v0.0.27

### PVE 9.3-ready storage UI and APIVER 17 metadata

On **Proxmox VE 9.3+**, Add/Edit Storage uses the native `CustomInputPanel` driven by plugin metadata (field titles, advanced/hidden split, content types including `vm-vol` / `vm-state` / `ct-vol`, and `isolate-properties`). `www/NimbleEdit.js` returns early when that class exists so it cannot override the native form; it remains the Add/Edit UI on pre-9.3.

- `guest_volume_vtype` reports typed guest volume names when available.
- Plugindata `meta` / `advanced` / `hidden` / `display-name` aligned with the NimbleEdit Advanced tab so the native dialog keeps the same main vs advanced layout.
- postinst warns clearly when the GUI helper is missing from the expected path.

### Opt-in `san-multipath` (cluster multipath.cfg)

Optional boolean for hosts that ship PVE’s cluster multipath helpers (9.3+):

- Registers/unregisters volume WWIDs in `/etc/pve/multipath.cfg` on alloc/map/free (best-effort).
- Alloc/clone can derive the WWID from the Nimble `serial_number` (no LUN map required).
- `map_volume` registers SAN **before** plugin `conf.d` aliases; `activate_volume` does not take a redundant multipath.cfg lock.
- Distinct from PVE’s built-in **managed-multipath** (iSCSI plugin path) — this is Pure-style cluster WWID registration for custom SANs.
- postinst may add Nimble device settings under Multipath Overrides unless `NIMBLE_SKIP_MULTIPATH_OVERRIDES=1`.

### Faster VM start / map paths (discussion [#11](https://github.com/brngates98/pve-nimble-plugin/discussions/11))

Addresses long per-disk delays (~20–24s) when sessions were already up but the node DB looked empty:

- **Session already up:** `nimble_iscsi_establish_volume_session` returns immediately when `iscsiadm -m session` lists the volume IQN — no ACL/sendtargets wait.
- **Already mapped:** `map_volume` skips rescan, udev settle, and the long device wait when the block device is already present.
- Map only requires **any** live session (not every node-DB portal) before skipping establish; missing portals can be filled with login-only.
- Targeted iSCSI rescans by session ID (`-r <sid> --rescan`) instead of host-wide session rescan.
- Shorter post-login session poll and colder-path udev settle.

---

## Highlights

| Area | Change |
|------|--------|
| PVE 9.3 UI | Native dialog via plugindata; NimbleEdit early-out |
| APIVER 17 | isolate-properties, guest_volume_vtype, UI meta |
| san-multipath | Opt-in cluster multipath.cfg WWID registration |
| iSCSI map | Session-up + already-mapped fast paths (#11) |
| Rescan | Per-session targeted rescan |

---

## Upgrading

- Drop-in upgrade: `apt update && apt upgrade libpve-storage-nimble-perl` (or install the `.deb` from Assets).
- On a cluster, install on **every node**. postinst restarts `pvedaemon`, `pvestatd`, `pveproxy`, `pvescheduler`.
- No `storage.cfg` changes required for existing setups.
- To use cluster multipath registration on PVE 9.3+: add `san-multipath 1` (or enable **SAN Multipath (cluster)** in the storage dialog).
- After upgrade, cold starts with already-logged-in iSCSI sessions should no longer sit in multi-second ACL/sendtargets waits per disk.

---

## Requirements

- **Proxmox VE** 8.2+ (Debian bookworm) or 9.x (Debian trixie)
- **HPE Nimble** / **Alletra 5000/6000** with REST API enabled (default port 5392)
- **iSCSI** initiator on each node (`open-iscsi`) with IQN in `/etc/iscsi/initiatorname.iscsi`
- (Optional) `nimble_initiator_group`; otherwise the plugin creates `pve-<nodename>` per node
- **`san-multipath`:** PVE 9.3+ host with cluster multipath helpers (`PVE::Multipath::Config`)

---

## Configuration

```bash
pvesm add nimble <storage_id> --nimble_address https://<nimble> \
  --username <user> --password '<password>' --content images,rootdir
```

PVE 9.3+ optional cluster multipath:

```bash
pvesm set <storage_id> --san-multipath 1
```

See the [README](https://github.com/brngates98/pve-nimble-plugin#configuration) for all options.

---

## Installation

- **APT – PVE 8 (bookworm):** `deb [...] https://brngates98.github.io/pve-nimble-plugin bookworm main`
- **APT – PVE 9 (trixie):** `deb [...] https://brngates98.github.io/pve-nimble-plugin trixie main`
- **Scripted install:** [README – scripted install](https://github.com/brngates98/pve-nimble-plugin#installation)
- **Manual:** Download `libpve-storage-nimble-perl_0.0.27-1_all.deb` from Assets and run `apt install ./…deb` or `dpkg -i`.

**Important:** On a cluster, install the plugin on every node.

---

## Documentation

| Document | Description |
|----------|-------------|
| [README](https://github.com/brngates98/pve-nimble-plugin#readme) | Install, config, troubleshooting |
| [docs/GUI_ADD_EDIT_STORAGE.md](https://github.com/brngates98/pve-nimble-plugin/blob/main/docs/GUI_ADD_EDIT_STORAGE.md) | Native 9.3 dialog vs NimbleEdit |
| [docs/API_VALIDATION.md](https://github.com/brngates98/pve-nimble-plugin/blob/main/docs/API_VALIDATION.md) | Plugin ↔ Nimble REST validation |
| [docs/NIMBLE_API_REFERENCE.md](https://github.com/brngates98/pve-nimble-plugin/blob/main/docs/NIMBLE_API_REFERENCE.md) | In-repo HPE REST API extract |
| [docs/AI_PROJECT_CONTEXT.md](https://github.com/brngates98/pve-nimble-plugin/blob/main/docs/AI_PROJECT_CONTEXT.md) | Maintainer / AI context |

---

## Package

- **Name:** `libpve-storage-nimble-perl`
- **Version:** 0.0.27-1
- **Install path:** `NimbleStoragePlugin.pm` → `/usr/share/perl5/PVE/Storage/Custom/`
- **Maintainer scripts:** postinst try-restarts `pvedaemon`, `pvestatd`, `pveproxy`, `pvescheduler`; may update Multipath Overrides; postrm does the same on remove/purge.

---

## Contributors and quality

- **CI:** Unit tests (APIVER 17 / isolate / san-multipath / session fast paths), plugin syntax (bookworm + trixie) must pass before the release deb build.
- Docker co-install verify resolves `nimble_*` via `get_property_schema` when `isolate-properties` is on (APIVER 17 / PVE 9.3 trixie), so the syntax job matches isolated registration.
- Addresses discussion [#11](https://github.com/brngates98/pve-nimble-plugin/discussions/11) (GUI path + start delays).
