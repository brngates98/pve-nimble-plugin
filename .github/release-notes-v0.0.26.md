# Release notes – v0.0.26

**Proxmox VE Plugin for HPE Nimble Storage (iSCSI)**

This plugin adds HPE Nimble Storage as a custom storage backend in Proxmox VE. It uses the Nimble REST API to create and manage volumes and presents them as VM disks (and LXC root volumes) over iSCSI, with optional multipath.

---

## What is new in v0.0.26

### PVE storage APIVER 17 (closes [#12](https://github.com/brngates98/pve-nimble-plugin/issues/12))

Proxmox raised the storage plugin API again during the PVE 9.2 point releases. Plugins that still report an older version load fine but print:

`Plugin "PVE::Storage::Custom::NimbleStoragePlugin" is implementing an older storage API, an upgrade is recommended`

on every `pvesm` / `pct` call.

- `api()` now advertises up to **APIVER 17** (current on `libpve-storage-perl` 9.1.17+ / PVE 9.2.29+).
- Negotiation still returns the host version on older packages (including **16** on 9.1.13 from issue #12), so one package covers both.
- APIVER 16/17 changes used by this plugin are additive (format helpers unused; guest volume types still reported as `images`).

### Multipath / iSCSI field hardening

Operational fixes from production use:

- **Alias-aware multipath teardown** — resolve dm maps via `mpath-<wwid>` UUIDs so `multipath -f` works when aliases are set (WWID-named `/dev/mapper/<wwid>` does not exist).
- **Coalesced `multipathd reconfigure`** — host-wide flock, min gap, and pending retry so pvestatd / multi-storage load does not wedge multipathd.
- **Stale iSCSI prune** — when baseline auto-discovery is on, prune IQNs the array no longer reports (grace period + in-use guards) so deleted volumes stop spamming `login rejected` on other nodes.
- **Safer logout** — session-id logout plus node-DB delete; skip nested cfs locks in `free_image` / `rename_volume` via `$STORAGE_LOCK_HELD`.
- **`deactivate_volume`** — drop the per-volume session only when baseline discovery is off and the map is not open; clean stacked partition maps first.

---

## Upgrading

- Drop-in upgrade: `apt update && apt upgrade libpve-storage-nimble-perl` (or install the `.deb` from Assets).
- On a cluster, install on **every node**. postinst restarts `pvedaemon`, `pvestatd`, `pveproxy`, `pvescheduler`.
- No `storage.cfg` changes required.
- After upgrade, `pvesm status` should no longer print the older-API warning on PVE 9.2 hosts at APIVER 16 or 17.

---

## Requirements

- **Proxmox VE** 8.2+ (Debian bookworm) or 9.x (Debian trixie)
- **HPE Nimble** / **Alletra 5000/6000** with REST API enabled (default port 5392)
- **iSCSI** initiator on each node (`open-iscsi`) with IQN in `/etc/iscsi/initiatorname.iscsi`
- (Optional) `nimble_initiator_group`; otherwise the plugin creates `pve-<nodename>` per node

---

## Configuration

```bash
pvesm add nimble <storage_id> --nimble_address https://<nimble> \
  --username <user> --password '<password>' --content images,rootdir
```

See the [README](https://github.com/brngates98/pve-nimble-plugin#configuration) for all options.

---

## Installation

- **APT – PVE 8 (bookworm):** `deb [...] https://brngates98.github.io/pve-nimble-plugin bookworm main`
- **APT – PVE 9 (trixie):** `deb [...] https://brngates98.github.io/pve-nimble-plugin trixie main`
- **Scripted install:** [README – scripted install](https://github.com/brngates98/pve-nimble-plugin#installation)
- **Manual:** Download `libpve-storage-nimble-perl_0.0.26-1_all.deb` from Assets and run `apt install ./…deb` or `dpkg -i`.

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
- **Version:** 0.0.26-1
- **Install path:** `NimbleStoragePlugin.pm` → `/usr/share/perl5/PVE/Storage/Custom/`
- **Maintainer scripts:** postinst try-restarts `pvedaemon`, `pvestatd`, `pveproxy`, `pvescheduler`; postrm does the same on remove/purge.

---

## Contributors and quality

- **CI:** Unit tests (including APIVER 17 negotiation and portal-host helpers), plugin syntax (bookworm + trixie) must pass before the release deb build.
- Closes [#12](https://github.com/brngates98/pve-nimble-plugin/issues/12).
