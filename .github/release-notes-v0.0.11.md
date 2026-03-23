# Release notes – v0.0.11

**Proxmox VE Plugin for HPE Nimble Storage (iSCSI)**

This plugin adds HPE Nimble Storage as a custom storage backend in Proxmox VE. It uses the Nimble REST API to create and manage volumes and presents them as VM disks over iSCSI, with optional multipath.

---

## What is new in v0.0.11

- **Fix: disk size shows 0T after moving a disk to Nimble storage** – When a disk was moved from another storage backend to the Nimble plugin (e.g. from LVM or Ceph), the Proxmox hardware tab showed `size=0T` and any subsequent move of that disk failed with _"size may not be zero"_. The VM itself saw the correct disk size; only the PVE metadata was wrong.

  **Root cause:** The Nimble REST API list endpoint (`GET volumes` / `GET volumes?name=`) returns summary data. For freshly-created volumes it can return `size: 0` — the same truncated response that already affected `serial_number` and `target_name`. Immediately after `volume_import` completes, PVE calls `volume_size_info` on the new volume. That call hit the list endpoint, got `size: 0`, and PVE wrote `size=0` into the VM config.

  **Fix (two locations):**
  - `nimble_get_volume_id` – `size` is now included alongside `serial_number` and `target_name` in the condition that triggers a full `GET volumes/:id` detail fetch. The real provisioned size is copied back into the volume record before it is returned to callers.
  - `nimble_list_volumes` – If any volume in the list response carries `size: 0`, a `GET volumes/:id` detail fetch is performed inline for that volume so that `list_images` (the Proxmox hardware tab / storage browser) always reflects the real size. The per-volume fetch is `eval`-wrapped so a single API error cannot break the entire volume listing.

- **Trixie (Debian 13 / PVE 9) APT repository** – The GitHub Pages APT repo now publishes both `dists/bookworm` (PVE 8) and `dists/trixie` (PVE 9) from the same package pool. The `.deb` is `Architecture: all` (pure Perl) so the same file works on both distributions. Users on PVE 9.1.1 can point their APT source at the `trixie` dist; users on PVE 8 continue to use `bookworm` unchanged.

- **CI: trixie syntax check** – The `checks` workflow now runs a `plugin-syntax-trixie` job alongside the existing `plugin-syntax-bookworm` job. Both jobs run `perl -c` against Proxmox's `libpve-storage-perl` in Docker (`debian:bookworm-slim` / `debian:trixie-slim`), ensuring the plugin compiles cleanly on both PVE generations on every push and pull request.

- **`verify_plugin_in_docker.sh` parameterized** – The local Docker syntax-check script now accepts a `DIST` environment variable (default: `bookworm`). Set `DIST=trixie` to validate against PVE 9 packages locally without a separate script.

---

## Upgrading from v0.0.10

No storage config changes required.

**Disk size fix applies automatically.** After upgrading, the next `list_images` call (GUI refresh or `pvesm list <storeid>`) will return correct sizes for all volumes. Any disk previously imported or moved with a `size=0` entry in the VM config can be corrected by editing the hardware config to set the correct size, or by removing and re-adding the disk entry after the upgrade (the data on the Nimble volume is unaffected).

**Trixie APT source (PVE 9 users):**
```bash
# Replace bookworm with trixie in your existing sources file, e.g.:
sed -i 's/ bookworm / trixie /' /etc/apt/sources.list.d/pve-nimble.list
apt-get update && apt-get install --only-upgrade libpve-storage-nimble-perl
```

---

## Highlights (full product)

- **Full PVE storage integration** – Create, delete, resize, and rename Nimble volumes from the Proxmox UI or CLI. One LUN per VM disk; no manual LUN provisioning.
- **Snapshots and clones** – VM snapshots use array snapshots (create, delete, rollback). Clone from snapshot creates a new volume via the Nimble clone API and attaches ACL + optional volume collection.
- **Backup / restore disk images** – `raw+size` import and export; MiB-rounded allocation.
- **Automatic initiator and ACL** – Optional pre-created initiator group, or the plugin creates a group per node (`pve-<nodename>`) using the host IQN and grants access via access control records.
- **Auto iSCSI discovery (default on)** – Discovery IPs from subnets (and fallbacks) drive `iscsiadm` on storage activation unless `auto_iscsi_discovery` is `no`/`0`.
- **Live VM migration** – `multi_initiator=true` (set at create time and auto-applied to existing volumes on activate) enables simultaneous iSCSI sessions from source and destination nodes.
- **Volume collections (protection plans)** – Optional `volume_collection` for array-side schedules.
- **Multipath** – By-id / WWN-aware discovery, multipathd add/remove, taint-safe external commands.
- **PVE 8 + PVE 9 support** – Tested on Debian bookworm (PVE 8) and trixie (PVE 9.1.1).

---

## Features at a glance

| Feature | Description |
|--------|-------------|
| **Volume lifecycle** | Create, delete, resize, rename volumes on the array via REST API |
| **ACL / initiator** | Optional `initiator_group` or auto `pve-<nodename>` with local IQN; access_control_records for each volume |
| **Snapshots** | Create, delete, rollback (in-place restore from snapshot) |
| **Clone from snapshot** | New volume from snapshot (POST volumes with clone=true); then ACL + optional volume_collection |
| **Import / export** | `raw+size` format for disk backup/restore; MiB-rounded allocation |
| **Multipath** | By-id + WWID forms; multipathd add/remove; safe under Perl `-T` |
| **Auto iSCSI discovery** | GET subnets + GET subnets/:id (authoritative portals); optional `iscsi_discovery_ips`; session IPs last resort |
| **Token cache** | Session token cached under `/etc/pve/priv/nimble/<storeid>.json` (cluster-safe) |
| **Live VM migration** | `multi_initiator=true` on all volumes; ACL + session ensured on destination before map |
| **Disk move / import** | `volume_size_info` and `list_images` always return real provisioned size (v0.0.11+) |
| **APT upgrade** | postinst try-restarts core PVE services (v0.0.9+) |
| **PVE 8 + PVE 9** | bookworm and trixie APT dists; CI validates both (v0.0.11+) |

---

## Requirements

- **Proxmox VE** 8.2+ (Debian bookworm) or 9.x (Debian trixie)
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

- **APT – PVE 8 (bookworm):** `deb [...] https://brngates98.github.io/pve-nimble-plugin bookworm main`
- **APT – PVE 9 (trixie):** `deb [...] https://brngates98.github.io/pve-nimble-plugin trixie main`
- **Scripted install:** See [README – Option C](https://github.com/brngates98/pve-nimble-plugin#option-c-scripted-installer-single-node-or-all-cluster-nodes) for `install-pve-nimble-plugin.sh`.
- **Manual:** Download `libpve-storage-nimble-perl_0.0.11-1_all.deb` from Assets and run `apt install ./…deb` or `dpkg -i`.

**Important:** On a cluster, install the plugin on every node.

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
- **Version:** 0.0.11-1
- **Install path:** `NimbleStoragePlugin.pm` → `/usr/share/perl5/PVE/Storage/Custom/`
- **Maintainer scripts:** **postinst** restarts core PVE systemd units on **configure** (install/upgrade) when **`/run/systemd/system`** exists.

---

## Contributors and quality

- **CI:** Every push and pull request to `main` runs unit tests and `perl -c` against both Proxmox PVE 8 (bookworm) and PVE 9 (trixie) in Docker.
- **Local check:** `./scripts/verify_plugin_in_docker.sh` (bookworm) or `DIST=trixie ./scripts/verify_plugin_in_docker.sh` (trixie). Requires Docker.
