# Proxmox VE Plugin for HPE Nimble Storage (iSCSI)

This plugin integrates HPE Nimble Storage arrays with Proxmox Virtual Environment (VE) over iSCSI. It uses the Nimble REST API to create and manage volumes and presents them as VM disks with optional multipath.

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
- An **initiator group** on the Nimble array that contains this host’s iSCSI IQN (create via Nimble UI or API)

### iSCSI on Proxmox

```bash
# Discover targets (use your Nimble iSCSI interface IP)
sudo iscsiadm -m discovery -t sendtargets -p <NIMBLE_ISCSI_IP>
sudo iscsiadm -m node --op update -n node.startup -v automatic
```

Ensure `/sys/class/iscsi_host/` has at least one host before using the plugin.

## Installation

### Manual

```bash
sudo apt-get install -y libwww-perl libjson-perl libjson-xs-perl liburi-perl
sudo mkdir -p /usr/share/perl5/PVE/Storage/Custom
sudo cp NimbleStoragePlugin.pm /usr/share/perl5/PVE/Storage/Custom/NimbleStoragePlugin.pm
sudo chmod 644 /usr/share/perl5/PVE/Storage/Custom/NimbleStoragePlugin.pm
sudo systemctl restart pvedaemon.service pveproxy.service
```

### Debian package (when built)

```bash
sudo apt install ./libpve-storage-nimble-perl_*_all.deb
```

## Configuration

Add storage via CLI (no GUI for custom types):

```bash
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
  initiator_group <initiator_group_name>
  content images
```

| Parameter         | Description |
|------------------|-------------|
| storage_id       | Name shown in Proxmox Storage list |
| address          | Nimble management URL (e.g. `https://nimble.example.com`). Port 5392 is used by default if omitted. |
| username         | Nimble REST API user |
| password         | API password |
| initiator_group  | **Required.** Nimble initiator group name that includes this host’s iSCSI IQN. Used for access_control_records when creating volumes. |
| vnprefix         | Optional prefix for volume names on the array |
| pool_name        | Optional Nimble pool for new volumes |
| check_ssl        | Set to `1` or `yes` to verify TLS (default: no) |
| token_ttl        | Session token cache TTL in seconds (default 3600) |
| content          | Use `images` for VM disks |

## Multipath (optional)

If you use multipath, configure it for Nimble (e.g. in `multipath.conf`) and ensure the plugin can find devices by serial. Device paths are resolved via `/sys/block/*/device/serial` and `/dev/disk/by-id/`.

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
