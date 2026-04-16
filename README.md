# Proxmox VE Plugin for HPE Nimble Storage (iSCSI)

Integrates HPE Nimble Storage with Proxmox VE over iSCSI. Manages volumes via the Nimble REST API and presents them as **QEMU VM disks** and **LXC container root** volumes (`rootdir`, raw block) with optional multipath.

## Overview

Once Nimble storage is added, it shows up under **Datacenter → Storage** like any other datastore: **type `nimble`**, content types you configured, usage from the array pool, and a **Summary** view with capacity over time.

![Proxmox Datacenter → Storage → Summary for a Nimble-backed store](https://raw.githubusercontent.com/brngates98/pve-nimble-plugin/main/docs/images/pve-storage-summary-nimble.png)

Array-created snapshots sync into the Proxmox VM snapshot tree as **`nimble*`** entries — visible alongside PVE snapshots with per-disk descriptions (`volume: snapshot name`):

![Proxmox VM snapshot tree with nimble* array-synced entries](https://raw.githubusercontent.com/brngates98/pve-nimble-plugin/main/docs/images/pve-vm-snapshots-nimble-tree.png)

**Screenshots:** More UI examples (VM Disks, snapshot dialogs, live migration, HPE Nimble volume list) are in **[docs/images/](docs/images/)** — see the index **[docs/images/README.md](docs/images/README.md)**. All figures are embedded in the **[step-by-step setup guide](docs/00-SETUP-FULLY-PROTECTED-STORAGE.md)**.

## Requirements

- Proxmox VE 8.2+
- HPE Nimble array reachable on port 5392 (REST API)
- `open-iscsi` installed on each node with an IQN in `/etc/iscsi/initiatorname.iscsi`

## Installation

**Scripted install (recommended)** — sets up the APT repo, installs dependencies, restarts PVE services, and can install on every cluster node at once:

```bash
# Single node
curl -fsSL https://raw.githubusercontent.com/brngates98/pve-nimble-plugin/main/scripts/install-pve-nimble-plugin.sh | sudo bash

# All cluster nodes at once (dry-run first to validate, then install)
curl -fsSL https://raw.githubusercontent.com/brngates98/pve-nimble-plugin/main/scripts/install-pve-nimble-plugin.sh | sudo bash -s -- --all-nodes --dry-run
curl -fsSL https://raw.githubusercontent.com/brngates98/pve-nimble-plugin/main/scripts/install-pve-nimble-plugin.sh | sudo bash -s -- --all-nodes
```

Other options: `--yes` (non-interactive), `--version X.Y.Z` (pin a release), `--codename SUITE` (default `bookworm`).

**Manual APT**

```bash
echo "deb [trusted=yes] https://brngates98.github.io/pve-nimble-plugin bookworm main" \
  | sudo tee /etc/apt/sources.list.d/pve-nimble-plugin.list
sudo apt update && sudo apt install libpve-storage-nimble-perl
```

To upgrade: `sudo apt update && sudo apt upgrade libpve-storage-nimble-perl`

**Download .deb** — grab a specific release from the [releases page](https://github.com/brngates98/pve-nimble-plugin/releases):

```bash
sudo apt install ./libpve-storage-nimble-perl_<version>-1_all.deb
```

> **Cluster:** The plugin must be installed on every node. Storage config syncs via corosync, but the plugin file does not.

## Add Storage

No need to pre-create an initiator group — the plugin creates one automatically from this node's IQN.

```bash
pvesm add nimble <storage_id> \
  --address https://<nimble_ip_or_fqdn> \
  --username <user> \
  --password '<password>' \
  --content images,rootdir
```

Use `images` only if you do not want LXC root disks on this store. Then in the Proxmox UI: **Datacenter → Storage** — your Nimble storage appears. Create a VM or container with storage on this pool.

## Configuration Options

| Option | Required | Description |
|--------|----------|-------------|
| `address` | Yes | Nimble management URL, e.g. `https://nimble.example.com`. Port 5392 is used by default. |
| `username` | Yes | Nimble REST API username |
| `password` | Yes | API password. Stored in `storage.cfg` (cluster-replicated). Set via `pvesm add/set --password`. |
| `initiator_group` | No | Existing Nimble initiator group name. If omitted, the plugin auto-creates `pve-<nodename>` using this node's IQN. |
| `auto_iscsi_discovery` | No | Default `yes`. Runs iSCSI discovery and login when storage activates. Set to `no` to disable. |
| `iscsi_discovery_ips` | No | Extra discovery portals (comma-separated) beyond what the Nimble subnets API returns. |
| `vnprefix` | No | Prefix added to all volume names on the array |
| `pool_name` | No | Nimble pool for new volumes |
| `volume_collection` | No | Volume collection name. New volumes are added to this collection for array-side snapshot schedules. |
| `check_ssl` | No | Default `no`. Set to `yes` to verify TLS certificates. |
| `token_ttl` | No | Session token cache TTL in seconds (default `3600`) |
| `debug` | No | `0`=off, `1`=basic, `2`=verbose, `3`=trace |

**Example `storage.cfg` entry:**

```text
nimble: my-nimble
  address https://nimble.example.com
  username admin
  content images,rootdir
  # initiator_group my-pve-group   # optional
  # volume_collection pve-vols      # optional
```

## Feature comparison (vs other Proxmox storage)

How the **Nimble plugin** compares to common Proxmox storage types (NFS, LVM / LVM-thin, kernel iSCSI, Ceph RBD). ✅ = native / built-in, ⚠️ = depends on extra layer or setup, ❌ = not supported.

| Feature | Nimble plugin | NFS | LVM / LVM-thin | iSCSI (kernel) | Ceph RBD |
|--------|----------------|-----|----------------|----------------|----------|
| **Snapshots** | ✅ | ⚠️ | ⚠️ | ⚠️ | ✅ |
| **VM state snapshots (vmstate)** | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Clones** | ✅ | ⚠️ | ⚠️ | ⚠️ | ✅ |
| **Thin provisioning** | ✅ | ⚠️ | ⚠️ | ⚠️ | ✅ |
| **Block-level performance** | ✅ | ❌ | ✅ | ✅ | ✅ |
| **Shared storage** | ✅ | ✅ | ⚠️ | ✅ | ✅ |
| **Automatic volume management** | ✅ | ❌ | ❌ | ❌ | ✅ |
| **Multi-path I/O** | ✅ | ❌ | ⚠️ | ⚠️ | ❌ |
| **Container storage (rootdir)** | ✅ | ✅ | ✅ | ❌ | ✅ |
| **Backup storage (vzdump)** | ❌ | ✅ | ❌ | ❌ | ❌ |
| **ISO storage** | ❌ | ✅ | ❌ | ❌ | ❌ |
| **Raw image format** | ✅ | ✅ | ✅ | ✅ | ✅ |

### Content types (what each storage can hold)

| Content type | Nimble plugin | NFS | LVM / LVM-thin | iSCSI (kernel) | Ceph RBD |
|-------------|----------------|-----|----------------|----------------|----------|
| **VM disks** | ✅ | ✅ | ✅ | ✅ | ✅ |
| **CT volumes (rootdir)** | ✅ | ✅ | ✅ | ❌¹ | ✅ |
| **Backups (vzdump)** | ❌ | ✅ | ❌ | ❌ | ❌ |
| **ISO images** | ❌ | ✅ | ❌ | ❌ | ❌ |
| **CT templates (vztmpl)** | ❌ | ✅ | ❌ | ❌ | ❌ |
| **Snippets** | ❌ | ✅ | ❌ | ❌ | ❌ |

¹ *Plain* PVE iSCSI storage does not expose `rootdir`; use LVM (or similar) on top of the LUN, or a plugin like this one that manages volumes and presents block devices.

Per-storage narratives (when to pick NFS vs RBD vs Nimble, and so on) live in **[docs/STORAGE_FEATURES_COMPARISON.md](docs/STORAGE_FEATURES_COMPARISON.md)**.

**Contributors:** Keep the two tables above in sync with the same tables in `docs/STORAGE_FEATURES_COMPARISON.md` when you change either copy (see [CONTRIBUTING.md](CONTRIBUTING.md#documentation)).

## Multipath (optional)

Configure `/etc/multipath.conf` with `find_multipaths no` and add Nimble to `blacklist_exceptions`:

```text
defaults {
    user_friendly_names yes
    find_multipaths     no
}
blacklist {
    devnode "^(ram|raw|loop|fd|md|dm-|sr|scd|st)[0-9]*"
    devnode "^hd[a-z]"
    device { vendor ".*" product ".*" }
}
blacklist_exceptions {
    device { vendor "Nimble" product "Server" }
}
devices {
    device {
        vendor               "Nimble"
        product              "Server"
        path_grouping_policy group_by_prio
        prio                 "alua"
        hardware_handler     "1 alua"
        path_selector        "service-time 0"
        path_checker         tur
        no_path_retry        30
        failback             immediate
        fast_io_fail_tmo     5
        dev_loss_tmo         infinity
    }
}
```

After editing, run `multipathd reconfigure`.

> **Alias management:** The plugin automatically writes per-volume WWID→alias entries to `/etc/multipath/conf.d/nimble-<storeid>.conf` when volumes are mapped, and restores them on `activate_storage`. You do not need to manage this file manually — but do not hand-edit it, as the plugin owns it.

## Lab validation (informal)

The maintainer has exercised most day-to-day flows on **real Proxmox VE + HPE Nimble** (volumes, QEMU VM and LXC root disks where applicable, PVE and array snapshots, rollback, clone, move disk, capacity/status, multipath, array snapshot import into the VM snapshot list including snap time and descriptions). That is **not** a guarantee for every firmware or cluster layout; treat your own checks as authoritative.

**Screenshots:** See **[Overview](#overview)** and **[docs/images/README.md](docs/images/README.md)**.

## Troubleshooting

### Common errors

| Error | Fix |
|-------|-----|
| `could not read local iSCSI IQN` | Install `open-iscsi`, add `InitiatorName=iqn.…` to `/etc/iscsi/initiatorname.iscsi`, restart `iscsid` |
| `Initiator group X not found` | Group set in config doesn't exist on the array. Create it in the Nimble UI or remove `initiator_group` from config to auto-create |
| API timeout / TLS error | Check `address`, firewall (port 5392), and set `check_ssl no` if using self-signed certs |
| No iSCSI session / map timeout | Run `iscsiadm -m session` on the affected node. Check L3 connectivity to Nimble data IPs. Use `iscsi_discovery_ips` if the subnets API doesn't return the right portals |
| Multipath not used | Confirm `multipathd` is running and Nimble is in `blacklist_exceptions` in `/etc/multipath.conf` |

### Debug logging

```bash
# Enable persistent debug (stored in config)
pvesm set <storage_id> --debug 1

# One-off debug for a single command
NIMBLE_DEBUG=1 pvesm list <storage_id>

# View logs (task log is often more useful than journalctl for migrate errors)
journalctl -u pvedaemon -f
```

For migrate/map failures, check the **task log** in the Proxmox UI (Datacenter → Task History) on the **target** node — that's where `map_volume` runs.

### Useful commands

```bash
# Verify API access
curl -sk -X POST "https://<nimble>:5392/v1/tokens" \
  -H "Content-Type: application/json" \
  -d '{"data":{"username":"<user>","password":"<password>"}}'

# iSCSI sessions
iscsiadm -m session
iscsiadm -m session --rescan

# Multipath
multipath -ll | grep -A 10 "Nimble"

# Token cache
ls -la /etc/pve/priv/nimble/

# Restart PVE services after plugin update
systemctl restart pvedaemon pveproxy pvestatd
```

## Features

- Create, delete, resize, rename volumes via Nimble REST API
- **VM disks** (`images`) and **LXC CT roots** (`rootdir`) on raw Nimble volumes — set `content` as in **Add Storage** (typically `images,rootdir`)
- Initiator group management (auto-create or use existing)
- Storage-level snapshots: create, delete, rollback
- Clone from snapshot
- Array snapshot sync: Nimble array-created snapshots are imported into **QEMU** VM configs automatically (visible in the Proxmox UI snapshot list; LXC/`rootdir` is not part of this sync path — see [AI project context](docs/AI_PROJECT_CONTEXT.md)). The snapshot **description** lists each LUN as **array volume name**, a colon, and the **Nimble snapshot name**; multiple disks in one PVE snapshot are separated by semicolons.
- Live migration (shared iSCSI block storage)
- Optional multipath with automatic alias management (`/etc/multipath/conf.d/nimble-<storeid>.conf`)
- Veeam Backup & Replication V13+ compatible (`raw+size` import/export)
- Token cache under `/etc/pve/priv/nimble/` (cluster-safe)

## Documentation

**Index:** [docs/README.md](docs/README.md) — guides, API docs, and developer material in one place (explains the `00-…` guide name and what each file is for).

| Audience | Start here |
|----------|------------|
| **Operators** | This README (install, config, [Overview](#overview) screenshots, feature comparison tables, troubleshooting). [Full setup walkthrough](docs/00-SETUP-FULLY-PROTECTED-STORAGE.md). [Extended feature comparison + storage-type guide](docs/STORAGE_FEATURES_COMPARISON.md). [All screenshots](docs/images/README.md). |
| **API / integration** | [Nimble REST reference (in-repo)](docs/NIMBLE_API_REFERENCE.md), [plugin ↔ API validation](docs/API_VALIDATION.md). |
| **Contributors / tooling** | [CONTRIBUTING.md](CONTRIBUTING.md), [AI / project context](docs/AI_PROJECT_CONTEXT.md), [tests](tests/README.md). |

## License

MIT — see [LICENSE](LICENSE).
