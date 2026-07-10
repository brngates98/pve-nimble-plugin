# Release notes – v0.0.26

**Proxmox VE Plugin for HPE Nimble Storage (iSCSI)**

This plugin adds HPE Nimble Storage as a custom storage backend in Proxmox VE. It uses the Nimble REST API to create and manage volumes and presents them as VM disks (and LXC root volumes) over iSCSI, with optional multipath.

---

## What is new in v0.0.26

### iSCSI Discovery Optimization
The `nimble_iscsi_discovery_ips` option has been upgraded from a supplement to a **strict override**. 
- **Behavior**: When set, the plugin uses ONLY these specified IPs for discovery. It skips the Nimble subnets and network\_interfaces API queries entirely.
- **Benefit**: This prevents `iscsiadm sendtargets` from hanging or timing out when the array reports subnets that are unreachable from the Proxmox node (e.g., due to VLAN restrictions or firewall rules).

### Quality of Service (QoS) Limits
The plugin now supports setting performance constraints on volumes created or cloned through Proxmox.
- **New Options**: 
  - `nimble_limit_iops`: IOPS limit for new volumes (Range: 256–4,294,967,294, or -1 for unlimited).
  - `nimble_limit_mbps`: Throughput limit in MB/s for new volumes (Range: 1–4,294,967,294, or -1 for unlimited).
- **Application**: Limits are applied during the `POST v1/volumes` request. Note that these do not retroactively change existing volumes.

### Volume Management & Compatibility
- **Nimble Folder Support**: Added the `nimble_folder` option. New volumes are now created inside the specified Nimble folder instead of the root folder.
- **Prefix Fallback Logic**: Implemented a name resolution fallback. If a volume was created before `nimble_vnprefix` was configured (or imported externally), the plugin can now locate the "bare" volume on the array, ensuring snapshots and clones still work for legacy volumes.
- **Enhanced Logging**: Added detailed info logs for volume creation, ACL granting, and the server-side instant copy process during cloning.

### Web UI & Configuration
- **GUI Integration**: The Proxmox storage configuration panel (`NimbleEdit.js`) now includes input fields for QoS limits, Discovery Portals, and other advanced options.
- **Config Flexibility**: `nimble_address` and `username` are now marked as optional in the plugin schema to improve compatibility with various Proxmox versions.

---

## Upgrading

- **Existing configs keep working unchanged.** New options (`nimble_limit_iops`, `nimble_limit_mbps`, `nimble_folder`) default to unlimited/root.
- On a cluster, install the plugin on **every node** (`apt upgrade` from the GitHub Pages repo, or the `.deb` from Assets). postinst restarts `pvedaemon`, `pvestatd`, `pveproxy`, `pvescheduler`.

---

## Requirements

- **Proxmox VE** 8.2+ (Debian bookworm) or 9.x (Debian trixie)
- **HPE Nimble** array with REST API enabled (default port 5392)
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

- **CI:** Unit tests, plugin syntax, the full PVE::Storage register + init + createSchema load test, and a 10-iteration co-install load test (bookworm + trixie) must pass before the release deb build.