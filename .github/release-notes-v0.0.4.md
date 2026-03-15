# Release notes – v0.0.4

## Highlights

- **Auto iSCSI discovery (opt-in)** – When you enable `auto_iscsi_discovery` on a Nimble storage, the plugin automatically runs iSCSI discovery and login on each node when the storage is activated. No manual `iscsiadm` steps required.
  - **Flow:** The plugin ensures the initiator group exists on the array (same logic as volume create), fetches iSCSI discovery IPs from the Nimble **GET v1/subnets** API (subnets with `allow_iscsi` or type containing `data`), then runs `iscsiadm` discovery, sets `node.startup` to automatic, and logs in.
  - **Safety:** Option is off by default. Discovery and login are additive only. If the initiator group cannot be ensured (e.g. no IQN), subnets return no IPs, or `iscsiadm` is missing, the plugin logs a warning and does not fail storage activation.
  - **Cluster:** Each node runs discovery/login for itself when that node activates the storage.
- **Documentation** – README and `docs/AI_PROJECT_CONTEXT.md` updated with the new option, flow, and requirements. `docs/NIMBLE_API_REFERENCE.md` documents the subnets and network_interfaces endpoints for management and discovery IPs and notes plugin use of subnets for auto discovery.

## Configuration

Add or edit Nimble storage with auto discovery enabled:

```bash
pvesm add nimble <storage_id> --address https://<nimble> --username <user> --password '<pass>' --content images --auto_iscsi_discovery 1
```

Or in `/etc/pve/storage.cfg`:

```text
nimble: <storage_id>
  address https://<nimble>
  username <user>
  password <pass>
  content images
  auto_iscsi_discovery 1
```

**Requirements:** `open-iscsi` installed and an IQN set in `/etc/iscsi/initiatorname.iscsi`. The plugin does not install the initiator; it ensures the initiator group on the array and runs discovery/login.

## Installation

- **APT (Bookworm):** Add the repo from GitHub Pages (see README) or install the `.deb` from the Assets below.
- **Manual:** Download `libpve-storage-nimble-perl_*.deb` from Assets and install with `dpkg -i`.

## Upgrading from v0.0.3

No config changes required. Existing storage continues to work. To use auto iSCSI discovery, add `auto_iscsi_discovery 1` to the storage config (or set it in the GUI if your Proxmox version shows the option).
