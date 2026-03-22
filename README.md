# Proxmox VE Plugin for HPE Nimble Storage (iSCSI)

This plugin integrates HPE Nimble Storage arrays with Proxmox Virtual Environment (VE) over iSCSI. It uses the Nimble REST API to create and manage volumes and presents them as VM disks with optional multipath.

## Table of Contents

- [Quick start](#quick-start)
- [Features](#features)
- [Prerequisites](#prerequisites)
  - [iSCSI on Proxmox](#iscsi-on-proxmox)
  - [API connectivity](#api-connectivity)
- [Installation](#installation)
  - [Manual installation](#manual-installation)
  - [Debian package (recommended)](#debian-package-recommended)
    - [Option A: APT repository (GitHub Pages)](#option-a-apt-repository-github-pages)
    - [Option B: Download the package](#option-b-download-the-package)
- [Configuration](#configuration)
- [VM migration (live migration and move)](#vm-migration-live-migration-and-move)
- [Multipath (optional)](#multipath-optional)
  - [Example: HPE Nimble only](#example-hpe-nimble-only)
  - [Example: Nimble and Pure](#example-nimble-and-pure)
- [Troubleshooting](#troubleshooting)
  - [Common error messages](#common-error-messages)
  - [Debug logging](#debug-logging)
  - [Service status](#service-status)
  - [Diagnostic commands](#diagnostic-commands)
  - [Known issues](#known-issues)
- [Development](#development)
- [Storage features comparison](#storage-features-comparison)
- [Comparison with Pure Storage plugin](#comparison-with-pure-storage-plugin)
- [Project context (contributors / AI)](#project-context-contributors--ai)
- [License](#license)

## Quick start

1. **Install** the plugin (APT or [package](https://github.com/brngates98/pve-nimble-plugin/releases)) and ensure **open-iscsi** is installed with an IQN set in `/etc/iscsi/initiatorname.iscsi`.

2. **Add storage** (no need to create an initiator group on the array—the plugin will create one for this host):

   ```bash
   pvesm add nimble <storage_id> --address https://<nimble>:5392 \
     --username <user> --password '<password>' --content images
   ```

3. In the Proxmox UI: **Datacenter → Storage** — your Nimble storage should appear. Create a VM and add a disk from this storage to use it.

## Features

- Create, delete, resize, and rename volumes on the Nimble array via the REST API
- Map volumes to Proxmox hosts using Nimble initiator groups (ACLs)
- Storage-based snapshots (create, delete, rollback)
- Clone from snapshot
- Optional multipath (same pattern as the Pure Storage plugin)
- Session token caching under `/etc/pve/priv/nimble/` (cluster-safe)
- **Veeam V13+:** Compatible with Veeam Backup & Replication 13 and later for Proxmox VE (backup and restore of VM disks on this storage via `raw+size` import/export; snapshot names from Veeam are normalized for the array)

## Prerequisites

- Proxmox VE 8.2+ (or compatible storage API)
- HPE Nimble array with REST API enabled (default port 5392)
- iSCSI initiator configured on each Proxmox node (e.g. `open-iscsi`)
- (Optional) An initiator group on the Nimble array. If you omit it, the plugin creates one automatically using this host’s iSCSI IQN (from `/etc/iscsi/initiatorname.iscsi`).

### iSCSI on Proxmox

**Same outcome as manual PVE iSCSI (no duplicate storage entry needed):** In the GUI, **Datacenter → Storage → Add → iSCSI** with your Nimble **portal** (e.g. `192.168.221.120`), the volume’s **IQN** from the array, **Enabled**, and **Use LUNs directly**, then add a disk as **LUN 0** raw—that is the host-side pattern this plugin automates. Each Nimble volume has its own **per-volume IQN** with **LUN 0**. The plugin uses the REST API for the volume and ACL, runs **`iscsiadm` discovery/login** on the resolved portal list, sets **`node.startup=automatic`** for that target+portal (like **Enabled**), runs **`iscsiadm -m session --rescan`**, rescans SCSI, resolves **`/dev/disk/by-id`** by serial (raw block to the VM, like **Use LUNs directly**), and optional multipath.

Either use **auto iSCSI discovery** (recommended) or run discovery manually:

**Option A — Auto iSCSI discovery (opt-in)**  
When adding the storage, set `auto_iscsi_discovery 1`. When the storage is activated, the plugin will call the Nimble subnets API to get iSCSI discovery IPs, then run `iscsiadm` discovery and login on this host. No manual discovery steps needed. Requires `open-iscsi` and an IQN in `/etc/iscsi/initiatorname.iscsi`. See [Auto iSCSI discovery (opt-in)](#auto-iscsi-discovery-opt-in).

**Option B — Manual discovery**

```bash
# Discover targets (use your Nimble iSCSI interface IP)
sudo iscsiadm -m discovery -t sendtargets -p <NIMBLE_ISCSI_IP>
sudo iscsiadm -m node --op update -n node.startup -v automatic
```

Ensure `/sys/class/iscsi_host/` has at least one host before using the plugin.

### API connectivity

To verify the array is reachable and credentials work before adding storage in Proxmox:

```bash
# Get a session token (use -k if TLS is not verified)
# Nimble API requires the request body to be wrapped in "data"
curl -sk -X POST "https://<nimble>:5392/v1/tokens" \
  -H "Content-Type: application/json" \
  -d '{"data":{"username":"<user>","password":"<password>"}}'
```

Use the `session_token` from the response (under `data.session_token`) with `X-Auth-Token` for other calls (e.g. `GET /v1/volumes`).

## Installation

There are two methods: manual installation and Debian package from the [releases page](https://github.com/brngates98/pve-nimble-plugin/releases) (recommended).

> **Important:** On a cluster, install the plugin on every node; storage config syncs via corosync, but the plugin must be present on each node.

### Manual installation

Useful for development or installing from source.

```bash
sudo apt-get install -y libwww-perl libjson-perl libjson-xs-perl liburi-perl
sudo mkdir -p /usr/share/perl5/PVE/Storage/Custom
sudo cp NimbleStoragePlugin.pm /usr/share/perl5/PVE/Storage/Custom/NimbleStoragePlugin.pm
sudo chmod 644 /usr/share/perl5/PVE/Storage/Custom/NimbleStoragePlugin.pm
sudo systemctl restart pvedaemon.service pveproxy.service
```

### Debian package (recommended)

The package installs dependencies and is easy to upgrade.

#### Option A: APT repository (GitHub Pages)

After each release, an APT repo is published at GitHub Pages. Add it once, then use `apt install` / `apt upgrade`:

```bash
# Add the repo (Debian Bookworm; use your Proxmox base: bookworm, bullseye, etc.)
echo "deb [trusted=yes] https://brngates98.github.io/pve-nimble-plugin bookworm main" | sudo tee /etc/apt/sources.list.d/pve-nimble-plugin.list
sudo apt update
sudo apt install libpve-storage-nimble-perl
```

To upgrade when a new version is released: `sudo apt update && sudo apt upgrade libpve-storage-nimble-perl`.

From **v0.0.9** onward, the package **postinst** **try-restarts** `pve-cluster`, `pvedaemon`, `pvestatd`, `pveproxy`, and `pvescheduler` after install/upgrade (via `deb-systemd-invoke` or `systemctl`) so the new `NimbleStoragePlugin.pm` is loaded without a manual restart. Older packages still need `systemctl restart pvedaemon pveproxy` (or equivalent) after upgrade.

The repo is updated on each release; it contains the latest package only. Enable **GitHub Pages** in the repo (Settings → Pages → Source: **GitHub Actions**) so the release workflow can publish the APT repo.

#### Option B: Download the package

Replace `<PACKAGE_VERSION>` with the version you want (e.g. `0.0.1`). See the [releases page](https://github.com/brngates98/pve-nimble-plugin/releases) for versions.

```bash
PACKAGE_VERSION="<PACKAGE_VERSION>"
wget "https://github.com/brngates98/pve-nimble-plugin/releases/download/v${PACKAGE_VERSION}/libpve-storage-nimble-perl_${PACKAGE_VERSION}-1_all.deb"
```

#### Install the package

```bash
sudo apt install ./libpve-storage-nimble-perl_${PACKAGE_VERSION}-1_all.deb
```

#### Verify installation

```bash
dpkg -l | grep libpve-storage-nimble-perl
# Should show the installed package version
```

#### To upgrade to a newer version

```bash
PACKAGE_VERSION="<NEW_VERSION>"
wget "https://github.com/brngates98/pve-nimble-plugin/releases/download/v${PACKAGE_VERSION}/libpve-storage-nimble-perl_${PACKAGE_VERSION}-1_all.deb"
sudo apt install ./libpve-storage-nimble-perl_${PACKAGE_VERSION}-1_all.deb
```

#### To uninstall

```bash
sudo apt remove libpve-storage-nimble-perl
```

#### Option C: Scripted installer (single node or all cluster nodes)

A script automates repo setup, package install, and PVE service restarts. It can install on the current node only or on every node in the cluster via SSH (same pattern as the Blockbridge PVE installer).

**Single node** (installs from APT repo; use `--version X.Y.Z` to install a specific release .deb from GitHub instead):

```bash
curl -fsSL https://raw.githubusercontent.com/brngates98/pve-nimble-plugin/main/scripts/install-pve-nimble-plugin.sh | sudo bash
```

**All cluster nodes** — validate first, then install:

```bash
# Validate cluster is healthy and all nodes are responding (no changes)
curl -fsSL https://raw.githubusercontent.com/brngates98/pve-nimble-plugin/main/scripts/install-pve-nimble-plugin.sh | sudo bash -s -- --all-nodes --dry-run

# Install on each node in the cluster
curl -fsSL https://raw.githubusercontent.com/brngates98/pve-nimble-plugin/main/scripts/install-pve-nimble-plugin.sh | sudo bash -s -- --all-nodes
```

Options: `--yes` (non-interactive), `--dry-run`, `--version X.Y.Z` (install that release from GitHub), `--codename SUITE` (default `bookworm`), `--help`. To review the script before running: download it, then run `bash ./install-pve-nimble-plugin.sh --help`.

## Configuration

Add storage via CLI (no GUI for custom types):

```bash
# Minimal: initiator group is created automatically from this host's IQN
# Like ESXi/CIFS: `password` is sensitive — pvesm stores it under /etc/pve/priv/storage/<storage_id>.pw (canonical, pmxcfs-replicated), mirrors to <storage_id>.nimble.pw and /etc/pve/priv/nimble/<storage_id>.pw for compatibility
# (not in storage.cfg). Use underscores in option names if you pass other flags (e.g. --auto_iscsi_discovery).
pvesm add nimble <storage_id> \
  --address https://<nimble_fqdn_or_ip> \
  --username <api_user> \
  --password '<api_password>' \
  --content images

# With auto iSCSI discovery (plugin runs discovery/login when storage is activated)
pvesm add nimble <storage_id> \
  --address https://<nimble_fqdn_or_ip> \
  --username <api_user> \
  --password '<api_password>' \
  --content images \
  --auto_iscsi_discovery 1

# Or specify an existing initiator group name
pvesm add nimble <storage_id> \
  --address https://<nimble_fqdn_or_ip> \
  --username <api_user> \
  --password '<api_password>' \
  --initiator_group <initiator_group_name> \
  --content images
```

Or edit `/etc/pve/storage.cfg`:

```text
nimble: <storage_id>
  address https://<nimble_fqdn_or_ip>
  username <api_user>
  content images
  # initiator_group <name>   # optional; omit to auto-create pve-<nodename>
  # auto_iscsi_discovery 1   # optional; run iSCSI discovery/login on activate (default: no)
  # iscsi_discovery_ips 192.168.221.120,192.168.222.120   # optional; merge with GET subnets if needed
```

| Parameter            | Description                                                                                                                                                                                                                                                                                                                                               |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| storage_id           | Name shown in Proxmox Storage list                                                                                                                                                                                                                                                                                                                        |
| address              | Nimble management URL (e.g. `https://nimble.example.com`). Port 5392 is used by default if omitted.                                                                                                                                                                                                                                                       |
| username             | Nimble REST API user (stored in `storage.cfg`)                                                                                                                                                                                                                                                                                                            |
| password             | **Proxmox does not provide a Datacenter GUI to add or edit custom storage plugins** (including `nimble`). Set it with **`pvesm add … --password`** / **`pvesm set <id> --password`**, the **cluster storage API**, or by creating the priv files yourself. Hooks write **`/etc/pve/priv/storage/<storage_id>.pw`** (same path as ESXi/CIFS), plus **`…/<storage_id>.nimble.pw`** and **`/etc/pve/priv/nimble/<storage_id>.pw`** for compatibility; not in `storage.cfg` when passed through `pvesm`/API. The plugin reads **`…/<id>.pw` first**, then the legacy names. You may put `password` in `storage.cfg` only if you maintain that by hand (not recommended). If a node still errors, run **`pvesm set <id> --password`** once from any member to rewrite the priv files.                                                                                          |
| initiator_group      | **Optional.** If unset, the plugin **reuses** the first iSCSI initiator group (API order) that already contains this host’s IQN and has **no CHAP** on any initiator (`chapuser_id`); if none match, it creates `pve-<nodename>`. If set, the plugin uses that group by name only (you create the group and IQNs in Nimble). Volume **access** (access control records) is added on create/activate when missing. |
| auto_iscsi_discovery | **Optional.** Set to `1` or `yes` to run iSCSI discovery and login when the **storage** is activated (early session setup). **Every VM disk map** also runs sendtargets + login against the same discovery IPs so new per-volume targets are seen—no need to rely on this flag for VM disks. Default: no.                                                                                                                                       |
| iscsi_discovery_ips | **Optional.** Comma-separated discovery portal addresses (same as `iscsiadm -m discovery -p …`). Merged with **`GET v1/subnets`**, **`GET network_interfaces`** (data/iSCSI NICs), or session-derived IPs. On **VM disk map**: quiet sendtargets once, then per-volume `iscsiadm -m node -T … -p … --login` only (no global `node --login`, which often exits 15 when many targets already have sessions).                                                                                                                                       |
| vnprefix             | Optional prefix for volume names on the array                                                                                                                                                                                                                                                                                                             |
| pool_name            | Optional Nimble pool for new volumes                                                                                                                                                                                                                                                                                                                      |
| volume_collection    | **Optional.** Nimble volume collection name. New volumes are added to this collection so array-side protection/snapshot schedules apply. Create the collection (and its protection template) in Nimble first.                                                                                                                                             |
| check_ssl            | Set to `1` or `yes` to verify TLS (default: no)                                                                                                                                                                                                                                                                                                           |
| token_ttl            | Session token cache TTL in seconds (default 3600)                                                                                                                                                                                                                                                                                                         |
| content              | Use `images` for VM disks                                                                                                                                                                                                                                                                                                                                 |

### VM migration (live migration and move)

- **Default (initiator_group unset):** If you already use a Nimble group whose members are your nodes’ IQNs (like typical LVM-over-iSCSI setups), the plugin **detects that group** and uses it instead of creating `pve-<nodename>`—first matching group in API order, **CHAP groups skipped**. Otherwise it creates `pve-<nodename>` with this node’s IQN. Volumes get ACLs to whichever group is in use; on **activate**, the plugin adds an ACL for that group if missing (so migration to another node works if that node’s IQN is in the **same** shared group, or each node uses its own group and activate adds that node’s group).
- **Shared initiator_group (optional):** If you set `initiator_group` to a group name, the plugin **looks up** that group and uses it for new volumes and for **access control records** on activate (same as auto mode: if the volume has no ACL to that group yet, the plugin adds one). It does **not** create the group or add IQNs—you must create the group in Nimble and add every node’s IQN. Use this for one shared group instead of per-node `pve-*` groups.

**Comparison with [kolesa-team/pve-purestorage-plugin](https://github.com/kolesa-team/pve-purestorage-plugin):** Pure **`activate_volume`** calls the array API to **create a volume connection** (host ↔ LUN) *before* **`map_volume`**. **`map_volume`** builds **`/dev/disk/by-id/wwn-0x…`** from the API serial plus a fixed vendor prefix and **waits until that path exists**—it does not read **`/sys/block/*/device/serial`** (multipath **dm** nodes often lack that file). It does **not** run `iscsiadm` in `map_volume`; operators pre-discover Pure portals once ([their README](https://github.com/kolesa-team/pve-purestorage-plugin#iscsi-configuration)). This Nimble plugin has no “connection” RPC: it sets **initiator group + access_control_records**, then runs **sendtargets + login** for the volume’s **`target_name`**. Device lookup follows the same **by-id / WWN idea as Pure**: try **`wwn-0x<serial>`** and any **`by-id`** name containing the API **`serial_number`**, then fall back to sysfs serial matching. Discovery IPs: **GET subnets** / sessions / **`iscsi_discovery_ips`**.

### Auto iSCSI discovery (opt-in)

If you set **auto_iscsi_discovery 1** (or **yes**) on the storage:

1. **When** the storage is activated on a node (e.g. after adding the storage or when the node first uses it), the plugin will:

   - **Ensure the initiator group exists** on the Nimble array (same logic as when creating volumes): if `initiator_group` is set in storage config, that group must exist; otherwise the plugin creates or finds a group named `pve-<nodename>` using this host's IQN from `/etc/iscsi/initiatorname.iscsi`. If this step fails (e.g. no IQN), auto discovery is skipped and a warning is logged.
   - Call **GET v1/subnets** and, when the list is summary-only, **GET v1/subnets/:id** for each row; use subnets whose **`type` contains `data`** and set **`discovery_ip`** as discovery portals (then fallbacks if none).
   - Run on this host: `iscsiadm -m discovery -t sendtargets -p <ip>` for each discovery IP, then set `node.startup` to `automatic`, then run `iscsiadm -m node --login`.

2. **Requirements:** `open-iscsi` must be installed and an IQN must be set in `/etc/iscsi/initiatorname.iscsi`. The plugin does not install or configure the initiator; it ensures the initiator group on the array, then runs discovery and login.

3. **Safety:** The option is off by default. The initiator group is ensured first (so the array knows this host's IQN); if that fails, discovery is skipped. Discovery and login are additive (they do not remove or overwrite existing iSCSI nodes). If the subnets API fails or returns no IPs, or if `iscsiadm` is missing, the plugin logs a warning and does not fail storage activation.

4. **Cluster:** On a cluster, activation runs per node; each node runs discovery/login for itself using the same Nimble subnets.

### Protection plans (Nimble-side)

On the Nimble array, **volume collections** group volumes and use a **protection template** to define snapshot schedule and retention (and optionally replication). To have the plugin put new disks under a protection plan:

1. In Nimble (UI or API), create a **protection template** with the desired schedule/retention, then create a **volume collection** using that template (or use an existing volume collection that already has a schedule).
2. Set **volume_collection** in the storage config to the **name** of that volume collection.
3. Every new volume (VM disk) created on this storage, and every volume created by **Clone** from snapshot, will be associated with that collection; the array will then snapshot it according to the collection's schedule.

Existing volumes are not moved into a collection; only newly created and cloned ones are. To add existing volumes to a collection, use the Nimble UI or REST API (PUT volume with `volcoll_id`).

### Backup and snapshot target

- **VM snapshots:** The plugin supports **storage-level snapshots**. When you take a VM snapshot in Proxmox and the VM has disks on this storage, the plugin creates a Nimble snapshot per disk; rollback and delete work as expected. So Nimble is already a "snapshot target" for VM snapshots.
- **vzdump backup target:** Proxmox backup (vzdump) expects **file** storage (directory, NFS, or Proxmox Backup Server). This plugin provides **block** (iSCSI) storage for VM disks. It does **not** support the "vzdump backup file" content type, so you cannot select this storage as a backup destination in PVE backup jobs. Use a file-based or PBS storage for backups.
- **Array-scheduled snapshots:** Nimble's own scheduled snapshots (from protection templates / volume collections) are created by the array, not by PVE. They do not appear as "VM snapshots" in the Proxmox UI. You can use **volume_collection** so new disks get array-side schedules; restore from those snapshots via the Nimble UI/API or by cloning/restore workflows outside PVE. See [Restore a disk from the array](docs/00-SETUP-FULLY-PROTECTED-STORAGE.md#11-restore-a-disk-from-the-array-workflow) for a step-by-step workflow (PVE rollback, clone, and in-place restore via Nimble UI or API).

### Veeam Backup & Replication (V13+)

The plugin is compatible with **Veeam Backup & Replication 13** and later when used with the Proxmox VE integration. It supports:

- **Backup:** Veeam can back up VMs whose disks are on this Nimble storage. The plugin exposes the `raw+size` export format so volume data can be streamed correctly.
- **Restore:** Restore of disks to this storage is supported via the `raw+size` import format. Volume size is rounded up to a full MB when needed (e.g. odd sector counts from backup), so restores complete without size-related failures.
- **Snapshot names:** If Veeam uses snapshot names with a `veeam_` prefix, the plugin normalizes them to `veeam-` on the array so Nimble snapshot names remain valid.

Install the plugin on every Proxmox node that hosts VMs backed by Veeam, and ensure iSCSI (and optional multipath) is configured as in the rest of this README.

## Multipath (optional)

If you use multipath, configure it in `/etc/multipath.conf` with `find_multipaths no`. In `blacklist_exceptions`, list every array vendor/product you use so only those (and not local disks) get multipathed; add a `devices` block per vendor.

### Example: HPE Nimble only

```text
defaults {
    user_friendly_names yes
    find_multipaths     no
}
blacklist {
    devnode "^(ram|raw|loop|fd|md|dm-|sr|scd|st)[0-9]*"
    devnode "^hd[a-z]"
    device {
        vendor  ".*"
        product ".*"
    }
}
blacklist_exceptions {
    device {
        vendor  "Nimble"
        product "Server"
    }
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
        rr_min_io_rq         1
        rr_weight            uniform
    }
}
```

### Example: Nimble and Pure

```text
defaults {
    polling_interval 2
    path_selector "round-robin 0"
    path_grouping_policy multibus
    uid_attribute ID_SERIAL
    rr_min_io 100
    failback immediate
    no_path_retry queue
    user_friendly_names yes
    find_multipaths no
}
blacklist {
    devnode "^(ram|raw|loop|fd|md|dm-|sr|scd|st)[0-9]*"
    devnode "^hd[a-z]"
    device {
        vendor  ".*"
        product ".*"
    }
}
blacklist_exceptions {
    device {
        vendor  "Nimble"
        product "Server"
    }
    device {
        vendor "PURE"
        product ".*"
    }
}
devices {
  device {
    vendor               "PURE"
    product              "FlashArray"
    path_selector        "queue-length 0"
    hardware_handler     "1 alua"
    path_grouping_policy group_by_prio
    prio                 alua
    failback             immediate
    path_checker         tur
    fast_io_fail_tmo     10
    user_friendly_names  no
    no_path_retry        0
    features             "0"
    dev_loss_tmo         60
    recheck_wwid         yes
  }
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
    rr_min_io_rq         1
    rr_weight            uniform
  }
}
```

The plugin adds and removes multipath maps at runtime via `multipathd` (using the device WWID).

After editing `/etc/multipath.conf`, run `multipathd reconfigure`. On SLES, set `user_friendly_names no` per SUSE recommendations.

Device paths are resolved via `/sys/block/*/device/serial` and `/dev/disk/by-id/`. For the official Nimble reference, see [HPE multipath.conf settings](https://support.hpe.com/hpesc/public/docDisplay?docId=sd00004361en_us&page=GUID-512951AE-9900-493C-9E3C-F3AA694E9771.html&docLocale=en_US).

## Troubleshooting

If you encounter issues while using the plugin, consider the following steps.

### Common error messages

| Problem                                    | What to do                                                                                                                                                                                                                    |
| ------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **"could not read local iSCSI IQN"**       | Install `open-iscsi`, set `InitiatorName=iqn.…` in `/etc/iscsi/initiatorname.iscsi`, then restart iscsid (or reboot).                                                                                                         |
| **"Initiator group X not found"**          | You set `initiator_group` in storage config but that group doesn’t exist on the array. Create it in the Nimble UI (with this host’s IQN) or remove `initiator_group` from the config so the plugin creates one automatically. |
| **API connection / timeout / TLS errors**  | Check `address` (use `https://` and correct host or IP), firewall (port 5392), and `check_ssl` (set to 0 or omit if using self-signed certs). Test with the [API connectivity](#api-connectivity) curl example.               |
| **Storage shows but VM disk create fails** | Enable debug (see below) and check token cache: `ls -la /etc/pve/priv/nimble/`.                                                                                                                                               |
| **Multipath not used**                     | Ensure multipathd is running, `/etc/multipath.conf` has Nimble in `blacklist_exceptions` (and a `devices` block if needed), then `multipathd reconfigure`.                                                                    |
| **pvedaemon won’t start: duplicate property `username` / `password`** | The plugin on disk is wrong or an old paste: those keys must **not** be in `properties()` (they clash with global PVE schema). They belong only in `options()`. Install the **full** `NimbleStoragePlugin.pm` from this repo or the package—do not merge by hand. Then `perl -c /usr/share/perl5/PVE/Storage/Custom/NimbleStoragePlugin.pm` and `systemctl restart pvedaemon pveproxy`. |
| **`undefined property 'nimble_password'` (or similar) in `pveproxy` / `pvedaemon` logs** | A storage key or `sensitive-properties` entry must be declared in the plugin’s **`properties()`**; PVE validates every `nimble:` section line. Remove any experimental `nimble_password` line from `/etc/pve/storage.cfg` and use the current plugin (only **`password`** is supported as the sensitive field, via `pvesm` / priv files). |
| **`multipathd add map` fails / wrong WWID** | Nimble multipath IDs often match **`dm-uuid-mpath-2…`** / **`scsi-2…`** (leading **`2`** + 32 hex), while **`wwn-0x…`** may show only the 32-hex NAA. The plugin maps **`wwn-0x` + 32 hex** → multipath WWID **`2` + same hex** and tries both forms. |
| **`Insecure dependency in exec` / `blockdev` / taint (`-T`)** | PVE runs custom storage plugins under **taint mode**. Device paths passed to **`exec`** must be **untainted** (validated with a regex capture). Use a current plugin that sanitizes `/dev/dm-*`, `/dev/sd*`, and multipath WWIDs before external commands. |

### Debug logging

The plugin writes debug output to syslog; you can view it in Proxmox logs.

**Enable debug logging:**

Persistent (via storage configuration):

```bash
pvesm set <storage_id> --debug 1
```

Temporary (for a single command, when debug is not set in config):

```bash
NIMBLE_DEBUG=1 pvesm list <storage_id>
```

If `debug` is set in storage configuration, it takes priority over the `NIMBLE_DEBUG` environment variable.

**Debug levels:**

- `0` – Off (default)
- `1` – Basic (token operations, main calls)
- `2` – Verbose (HTTP details, API responses)
- `3` – Trace (all internals)

**Example debug output:**

```bash
NIMBLE_DEBUG=1 pvesm list <storage_id>
Debug :: activate_storage (<storage_id>)
Debug :: Read token cache from: /etc/pve/priv/nimble/<storage_id>.json
```

**Common debug scenarios:**

Debug volume creation:

```bash
NIMBLE_DEBUG=2 pvesm alloc <storage_id> <vmid> <volname> 10G
```

Debug API authentication:

```bash
NIMBLE_DEBUG=3 pvesm status <storage_id>
```

**View debug logs:**

```bash
journalctl -u pvedaemon -f
journalctl -u pvedaemon | grep -E "(Debug ::|Info ::|Warning ::|Error ::)"
```

**Token cache:**

```bash
ls -la /etc/pve/priv/nimble/
cat /etc/pve/priv/nimble/<storage_id>.json | jq .
```

### Service status

Ensure Proxmox VE services are running. Restart if needed:

```bash
sudo systemctl restart pve-cluster.service pvedaemon.service pvestatd.service pveproxy.service pvescheduler.service
```

### Diagnostic commands

**Multipath:**

```bash
multipath -ll
multipath -ll -v3
multipath -ll | grep -A 10 "Nimble"
systemctl reload multipathd
```

Nimble has no fixed WWID prefix; devices are matched by SCSI serial from the array. Use the volume serial from the Nimble UI or API and match against `/sys/block/*/device/serial` or `/dev/disk/by-id/`.

**iSCSI:**

```bash
iscsiadm -m session
iscsiadm -m session -P 3
iscsiadm -m node
iscsiadm -m session --rescan
```

**Device and mapper:**

```bash
ls -l /dev/disk/by-id/
lsblk
dmsetup table
dmsetup ls --tree
```

**Storage plugin:**

```bash
pvesm list <storage_id>
pvesm status <storage_id>
pvesm scan <storage_id>
```

**Network connectivity:**

Test Nimble API (management, port 5392). Request body must be wrapped in `data`:

```bash
curl -sk -X POST "https://<nimble>:5392/v1/tokens" \
  -H "Content-Type: application/json" \
  -d '{"data":{"username":"<user>","password":"<password>"}}'
```

Test iSCSI portal (port 3260):

```bash
nc -zv <nimble_iscsi_ip> 3260
```

**Other checks:**

- **API credentials:** Use a Nimble user with permissions to create volumes and manage initiator groups and access control records.
- **Multipath configuration:** Verify `multipath.conf` (e.g. `find_multipaths no`, Nimble in `blacklist_exceptions`, Nimble `devices` block). See [Multipath (optional)](#multipath-optional).
- **Plugin updates:** Ensure you are using a supported plugin version.

### Known issues

**Debug output in command results:** When debug logging is enabled, debug messages can appear in outputs that scripts expect to be clean (e.g. `pvesm path`, `qm showcmd`). Disable debug for production or use `NIMBLE_DEBUG=1` only when running diagnostic commands.

**LVM on top of Nimble volumes:** If you use LVM inside a Nimble-backed volume, add the relevant device patterns to LVM’s `global_filter` in `/etc/lvm/lvmlocal.conf` so LVM does not scan those devices (e.g. by serial or `/dev/mapper/` pattern).

## Development

The plugin depends on Proxmox VE Perl modules (`PVE::Storage::Plugin`, `PVE::Tools`, etc.). Syntax and load testing should be done on a Proxmox node or in a PVE environment where those modules are installed.

## Storage features comparison

A feature-by-feature comparison of this plugin with NFS, LVM, LVM-thin, iSCSI, and Ceph RBD is in **[docs/STORAGE_FEATURES_COMPARISON.md](docs/STORAGE_FEATURES_COMPARISON.md)**. It covers content types (images, ISO, backup, etc.), thin provisioning, snapshots, clone, live migration, and multipath.

## Comparison with Pure Storage plugin

This plugin is based on the [pve-purestorage-plugin](https://github.com/kolesa-team/pve-purestorage-plugin) design:

- **Auth:** Nimble uses username/password → `POST /v1/tokens` → `X-Auth-Token`; Pure uses API token → login → `x-auth-token`.
- **Volumes:** Nimble uses `POST/GET/DELETE/PUT /v1/volumes` (size in MB); Pure uses its own volume and connection APIs.
- **ACL / connect–disconnect:** Same call order as Pure: **`nimble_volume_connection(1)`** before map, **`nimble_volume_connection(0)`** after unmap on deactivate, and remove **all** ACLs for the volume in **`nimble_remove_volume`** before destroy. The Nimble API uses `access_control_records` (vol + initiator group) instead of Pure’s host/volume connections; disconnect removes the ACL for **this storage’s** resolved initiator group (see `nimble_resolve_initiator_group_id_no_create`).
- **Snapshots:** Nimble `POST /v1/snapshots` (vol_id, name); Pure uses volume-snapshots and suffix naming.

## Project context (contributors / AI)

For resuming work or onboarding, see **[docs/AI_PROJECT_CONTEXT.md](docs/AI_PROJECT_CONTEXT.md)**. It summarizes what the project is, current status, layout, how the plugin works, and what might need doing next.

## License

Same as the Pure Storage plugin project (see LICENSE in the repo).
