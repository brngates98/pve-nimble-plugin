# Proxmox VE Plugin for HPE Nimble Storage (iSCSI)

This plugin integrates HPE Nimble Storage arrays with Proxmox Virtual Environment (VE) over iSCSI. It uses the Nimble REST API to create and manage volumes and presents them as VM disks with optional multipath.

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

## Prerequisites

- Proxmox VE 8.2+ (or compatible storage API)
- HPE Nimble array with REST API enabled (default port 5392)
- iSCSI initiator configured on each Proxmox node (e.g. `open-iscsi`)
- (Optional) An initiator group on the Nimble array. If you omit it, the plugin creates one automatically using this host’s iSCSI IQN (from `/etc/iscsi/initiatorname.iscsi`).

### iSCSI on Proxmox

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
curl -sk -X POST "https://<nimble>:5392/v1/tokens" \
  -H "Content-Type: application/json" \
  -d '{"username":"<user>","password":"<password>"}'
```

Use the `session_token` from the response with `X-Auth-Token` for other calls (e.g. `GET /v1/volumes`).

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

## Configuration

Add storage via CLI (no GUI for custom types):

```bash
# Minimal: initiator group is created automatically from this host's IQN
pvesm add nimble <storage_id> \
  --address https://<nimble_fqdn_or_ip> \
  --username <api_user> \
  --password <api_password> \
  --content images

# Or specify an existing initiator group name
pvesm add nimble <storage_id> \
  --address https://<nimble_fqdn_or_ip> \
  --username <api_user> \
  --password <api_password> \
  --initiator_group <initiator_group_name> \
  --content images
```

Or edit `/etc/pve/storage.cfg`:

```text
nimble: <storage_id>
  address https://<nimble_fqdn_or_ip>
  username <api_user>
  password <api_password>
  content images
  # initiator_group <name>   # optional; omit to auto-create pve-<nodename>
```

| Parameter         | Description |
|------------------|-------------|
| storage_id       | Name shown in Proxmox Storage list |
| address          | Nimble management URL (e.g. `https://nimble.example.com`). Port 5392 is used by default if omitted. |
| username         | Nimble REST API user |
| password         | API password |
| initiator_group  | **Optional.** Nimble initiator group name. If unset, the plugin creates a group named `pve-<nodename>` with this host’s iSCSI IQN and uses it for access_control_records. |
| vnprefix         | Optional prefix for volume names on the array |
| pool_name        | Optional Nimble pool for new volumes |
| check_ssl        | Set to `1` or `yes` to verify TLS (default: no) |
| token_ttl        | Session token cache TTL in seconds (default 3600) |
| content          | Use `images` for VM disks |

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

| Problem | What to do |
|--------|------------|
| **"could not read local iSCSI IQN"** | Install `open-iscsi`, set `InitiatorName=iqn.…` in `/etc/iscsi/initiatorname.iscsi`, then restart iscsid (or reboot). |
| **"Initiator group \"X\" not found"** | You set `initiator_group` in storage config but that group doesn’t exist on the array. Create it in the Nimble UI (with this host’s IQN) or remove `initiator_group` from the config so the plugin creates one automatically. |
| **API connection / timeout / TLS errors** | Check `address` (use `https://` and correct host or IP), firewall (port 5392), and `check_ssl` (set to 0 or omit if using self-signed certs). Test with the [API connectivity](#api-connectivity) curl example. |
| **Storage shows but VM disk create fails** | Run with debug: `NIMBLE_DEBUG=2 pvesm status` (or set `debug 2` in storage config). Check token cache: `ls -la /etc/pve/priv/nimble/`. |
| **Multipath not used** | Ensure multipathd is running, `/etc/multipath.conf` has Nimble in `blacklist_exceptions` (and a `devices` block if needed), then `multipathd reconfigure`. |

## Debug

- Set `debug` in storage config (0–3) or use `NIMBLE_DEBUG=1` in the environment when running `pvesm` commands.
- Token cache: `ls -la /etc/pve/priv/nimble/`

## Development

The plugin depends on Proxmox VE Perl modules (`PVE::Storage::Plugin`, `PVE::Tools`, etc.). Syntax and load testing should be done on a Proxmox node or in a PVE environment where those modules are installed.

## Comparison with Pure Storage plugin

This plugin is based on the [pve-purestorage-plugin](https://github.com/kolesa-team/pve-purestorage-plugin) design:

- **Auth:** Nimble uses username/password → `POST /v1/tokens` → `X-Auth-Token`; Pure uses API token → login → `x-auth-token`.
- **Volumes:** Nimble uses `POST/GET/DELETE/PUT /v1/volumes` (size in MB); Pure uses its own volume and connection APIs.
- **ACL:** Nimble uses initiator groups + `access_control_records` (vol_id + initiator_group_id); Pure uses host/volume connections.
- **Snapshots:** Nimble `POST /v1/snapshots` (vol_id, name); Pure uses volume-snapshots and suffix naming.

## Project context (contributors / AI)

For resuming work or onboarding, see **[docs/AI_PROJECT_CONTEXT.md](docs/AI_PROJECT_CONTEXT.md)**. It summarizes what the project is, current status, layout, how the plugin works, and what might need doing next.

## License

Same as the Pure Storage plugin project (see LICENSE in the repo).
