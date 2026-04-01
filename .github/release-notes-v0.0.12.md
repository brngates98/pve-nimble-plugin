# Release notes – v0.0.12

**Proxmox VE Plugin for HPE Nimble Storage (iSCSI)**

This plugin adds HPE Nimble Storage as a custom storage backend in Proxmox VE. It uses the Nimble REST API to create and manage volumes and presents them as VM disks over iSCSI, with optional multipath.

---

## What is new in v0.0.12

- **Array snapshot sync** – Array-created snapshots (from Nimble protection schedules or manual array-side snaps) are now automatically imported into PVE VM configs as usable snapshots. `status()` runs a background sync every 30 seconds: consistent snapshot groups (all disks for a VM covered within 60 seconds) appear in the Proxmox snapshot list as `nimble<timestamp>` entries. Stale entries are pruned when the array snapshot expires. Rollback and delete work on imported snapshots identically to PVE-created ones.

- **Multipath alias management** – The plugin now manages `/etc/multipath/conf.d/nimble-<storeid>.conf` with a stable `<storeid>-<volname>` alias for every mapped volume. WWID→alias mappings are cached in `/etc/pve/priv/nimble/<storeid>.wwid.json` so aliases are restored on `activate_storage` (reboot persistence) without needing the device to be present. Devices already defined in `/etc/multipath.conf` are skipped with a warning. Aliases are deregistered automatically on `free_image`.

- **APIVER 12/13 methods** – Implements `volume_snapshot_info`, `volume_rollback_is_possible`, `volume_qemu_snapshot_method` (returns `'storage'` so PVE/QEMU delegates snapshot management to the plugin), `qemu_blockdev_options` (returns `host_device` driver spec for mapped block nodes), and `rename_snapshot` (stub die — Nimble API does not support snapshot rename). Required for correct snapshot behaviour on PVE 9 / APIVER 12+.

- **`list_images` caching** – The volume list is now cached per `$cache->{nimble}{$storeid}` within a single PVE operation, eliminating redundant `GET volumes` REST calls when PVE iterates storage for multiple VMs in one pass (e.g. backup, migration planning). Callers receive a filtered shallow copy; the cache is not mutated by filters.

- **Fix: taint-unsafe backtick commands in multipath helpers** – `multipath_check` and `nimble_multipath_active_wwid` previously used backtick execution (`\`multipath -l ...\``), which bypasses `run_command` and is not safe under PVE's `perl -T` taint mode. Both are rewritten to use `run_command` with `outfunc`.

- **Fix: `block_device_slaves` crash in `unmap_volume`** – If the device path failed the whitelist validation inside `block_device_slaves`, the function would die and leave `unmap_volume` in an inconsistent state. It is now wrapped in eval with a warning; `unmap_volume` returns 0 cleanly instead of propagating the die.

- **Fix: snapshot name prefix collision** – Array-imported snapshot PVE names changed from `n<timestamp>` to `nimble<timestamp>`. PVE allows snapshot names matching `[a-zA-Z][a-zA-Z0-9_]{0,39}`, so `n<digits>` is a valid user-created name and the old cleanup pass could delete user snapshots. The `nimble` prefix is not a valid user-generated name.

- **Fix: unsafe `decode_json` calls** – Both `decode_json` call sites in `nimble_api_call` (login response and API response) are wrapped in `eval`. A non-JSON body (proxy error page, maintenance mode) now produces a clear error message with the API path and first 256 bytes of the response body instead of a cryptic Perl JSON parse crash.

- **Fix: unguarded `scsi_scan_new` in `map_volume`** – `scsi_scan_new('iscsi')` dies if `/sys/class/iscsi_host` does not exist (iSCSI kernel module not loaded). It is now wrapped in `eval`; a warning is emitted and the device-wait loop continues rather than aborting the map.

- **Docs: README simplified** – README reduced from ~600 to ~190 lines. Developer internals, API details, and verbose explanations moved to dedicated docs. Scripted install promoted as the recommended method.

- **Docs: setup guide refined** – Scripted install is now step 1; the redundant manual iSCSI step was removed; steps renumbered.

---

## Upgrading from v0.0.11

No storage config changes required. No manual migration steps needed.

**Array snapshot sync is on by default.** After upgrading, PVE VM configs for VMs with Nimble storage will gain `nimble<timestamp>` snapshot entries within 30 seconds of the first `status()` call. Existing PVE-created snapshots are unaffected.

**Multipath aliases are registered on next map.** The alias conf file and WWID cache are created the first time a volume is mapped after upgrade. On `activate_storage` (next node reboot or `pvesm activate <storeid>`), aliases are restored from the cache.

---

## Highlights (full product)

- **Full PVE storage integration** – Create, delete, resize, and rename Nimble volumes from the Proxmox UI or CLI. One LUN per VM disk; no manual LUN provisioning.
- **Snapshots and clones** – VM snapshots use array snapshots (create, delete, rollback). Array-created snapshots sync into PVE automatically. Clone from snapshot creates a new volume via the Nimble clone API.
- **Backup / restore disk images** – `raw+size` import and export; MiB-rounded allocation.
- **Automatic initiator and ACL** – Optional pre-created initiator group, or the plugin creates a group per node (`pve-<nodename>`) using the host IQN and grants access via access control records.
- **Auto iSCSI discovery (default on)** – Discovery IPs from subnets drive `iscsiadm` on storage activation unless `auto_iscsi_discovery` is `no`/`0`.
- **Live VM migration** – `multi_initiator=true` enables simultaneous iSCSI sessions from source and destination nodes.
- **Volume collections (protection plans)** – Optional `volume_collection` for array-side schedules.
- **Multipath** – By-id / WWN-aware discovery, multipathd add/remove, alias management, taint-safe external commands.
- **PVE 8 + PVE 9 support** – Tested on Debian bookworm (PVE 8) and trixie (PVE 9).

---

## Features at a glance

| Feature | Description |
|--------|-------------|
| **Volume lifecycle** | Create, delete, resize, rename volumes on the array via REST API |
| **ACL / initiator** | Optional `initiator_group` or auto `pve-<nodename>` with local IQN; access_control_records per volume |
| **Snapshots** | Create, delete, rollback; array-created snapshots sync to PVE automatically (v0.0.12+) |
| **Clone from snapshot** | New volume from snapshot (POST volumes with clone=true); ACL + optional volume_collection |
| **Import / export** | `raw+size` format for disk backup/restore; MiB-rounded allocation |
| **Multipath** | By-id + WWID forms; multipathd add/remove; alias management with conf.d + WWID cache (v0.0.12+) |
| **Auto iSCSI discovery** | GET subnets + GET subnets/:id (authoritative portals); optional `iscsi_discovery_ips` |
| **Token cache** | Session token cached under `/etc/pve/priv/nimble/<storeid>.json` (cluster-safe) |
| **Live VM migration** | `multi_initiator=true` on all volumes; ACL + session ensured on destination before map |
| **list_images cache** | Volume list cached per PVE operation; no redundant REST calls (v0.0.12+) |
| **APIVER 12/13** | `volume_snapshot_info`, `volume_qemu_snapshot_method`, `qemu_blockdev_options` (v0.0.12+) |
| **APT upgrade** | postinst try-restarts core PVE services (v0.0.9+) |
| **PVE 8 + PVE 9** | bookworm and trixie APT dists; CI validates both |

---

## Requirements

- **Proxmox VE** 8.2+ (Debian bookworm) or 9.x (Debian trixie)
- **HPE Nimble** array with REST API enabled (default port 5392)
- **iSCSI** initiator on each node (`open-iscsi`) with IQN in `/etc/iscsi/initiatorname.iscsi`
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
- **Manual:** Download `libpve-storage-nimble-perl_0.0.12-1_all.deb` from Assets and run `apt install ./…deb` or `dpkg -i`.

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
- **Version:** 0.0.12-1
- **Install path:** `NimbleStoragePlugin.pm` → `/usr/share/perl5/PVE/Storage/Custom/`
- **Maintainer scripts:** **postinst** restarts core PVE systemd units on **configure** (install/upgrade) when **`/run/systemd/system`** exists.

---

## Contributors and quality

- **CI:** Every push and pull request to `main` runs unit tests and `perl -c` against both Proxmox PVE 8 (bookworm) and PVE 9 (trixie) in Docker.
- **Local check:** `./scripts/verify_plugin_in_docker.sh` (bookworm) or `DIST=trixie ./scripts/verify_plugin_in_docker.sh` (trixie). Requires Docker.
