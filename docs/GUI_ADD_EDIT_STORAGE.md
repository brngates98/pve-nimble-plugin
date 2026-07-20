# Nimble Storage GUI Integration

## Overview

The Nimble Storage plugin now supports full GUI integration in the Proxmox VE web interface. You can:

- **Add** new Nimble storage via the Storage Add dropdown menu
- **Edit** existing Nimble storage via the Edit button

No manual `/etc/pve/storage.cfg` editing is required for basic storage configuration.

## How It Works

### Backend (Perl)

The `NimbleStoragePlugin.pm` module defines the storage type, properties, and API integration:

- `type()` returns `"nimble"`
- `plugindata()` declares content types, format, and sensitive properties
- `properties()` defines all `nimble_*` configuration options
- `options()` declares which properties are required/optional

### Frontend (JavaScript)

The `www/NimbleEdit.js` file provides the web GUI components:

- **`PVE.storage.NimbleInputPanel`**: ExtJS form panel with all configuration fields
  - Inherits from `PVE.panel.StorageBase` (provides ID, Nodes, Enable fields automatically)
  - Defines basic fields (column1, column2) and advanced fields (advancedColumn1, advancedColumn2)
  - Handles password masking on Edit (doesn't leak existing password, only sends if changed)
  - Removes empty optional fields before submitting

- **`PVE.Utils.storageSchema['nimble']`**: Registration entry
  - Makes "HPE Nimble" appear in the Add dropdown
  - Tells `createStorageEditWindow()` to use `NimbleInputPanel` for Edit dialogs
  - Sets `backups: false` (Nimble is block storage, not backup-capable)

### Deployment

During `.deb` installation, `debian/postinst`:

1. Copies `NimbleEdit.js` to `/usr/share/pve-manager/js/`
2. Injects a `<script>` tag into `/usr/share/pve-manager/index.html.tpl` (idempotent)
3. Restarts `pveproxy.service` to serve the modified template

During `.deb` removal, `debian/postrm`:

1. Removes the `<script>` tag from `index.html.tpl`
2. Restarts `pveproxy.service`

## Usage

### Adding Nimble Storage

1. Navigate to **Datacenter → Storage** in the PVE web UI
2. Click the **Add** button dropdown
3. Select **HPE Nimble**
4. Fill in the required fields:
   - **ID**: Unique storage identifier (e.g., `nimble1`)
   - **Array IP / DNS**: Nimble array management IP or hostname
   - **Username**: Nimble API username
   - **Password**: Nimble API password
   - **Content**: Select `Disk image` (and optionally `Container`)
5. Optional fields:
   - **Volume Name Prefix**: Prefix for volume names (default: `pve`)
   - **Pool Name**: Nimble pool for new volumes (default: array's default pool)
   - **Folder**: Nimble folder for new volumes (default: root; creation fails if the folder does not exist on the array)
   - **Initiator Group**: Pre-existing initiator group (default: auto-created from IQN)
6. Advanced settings (expand the Advanced tab):
   - **Volume Collection**: Add new volumes to this collection (applies array-side protection schedules)
   - **Discovery Portals**: Additional iSCSI discovery portals (comma-separated), merged with portals auto-detected from the Nimble subnets API
   - **Discovery Override**: Use **only** the Discovery Portals above; skip the Nimble subnets/network_interfaces APIs (default: off). Use when the array reports subnets this host cannot reach and sendtargets times out
   - **Session Token TTL**: API session token lifetime in seconds (default: 3600)
   - **Debug Level**: 0=off, 1=basic, 2=verbose, 3=trace (default: 0)
   - **Verify TLS Certificate**: Enable/disable TLS verification (default: disabled)
   - **Auto iSCSI Discovery**: Automatically discover and login to iSCSI targets (default: enabled)
   - **IOPS Limit / Throughput Limit MB/s**: QoS limits applied to newly created volumes and clones (default: unlimited; IOPS minimum is 256)
   - **Legacy Name Fallback**: Also resolve volumes by their bare un-prefixed array name (default: off). **Caution:** do not enable on multiple storages that share one array separated only by prefix
7. Click **Add**

### Editing Nimble Storage

1. Navigate to **Datacenter → Storage**
2. Select an existing Nimble storage entry
3. Click the **Edit** button
4. Modify fields as needed
   - **Note**: ID, Array IP, and Username are read-only (cannot be changed after creation)
   - **Password**: Leave empty to keep the existing password, or type a new password to change it
5. Click **OK**

## Field Mapping

| GUI Field | `storage.cfg` Key | Required | Notes |
|-----------|-------------------|----------|-------|
| ID | (section name) | Yes | Immutable after creation |
| Array IP / DNS | `nimble_address` | Yes | Immutable after creation |
| Username | `username` | Yes | Immutable after creation |
| Password | `password` | Yes on create | Stored in `/etc/pve/priv/storage/<id>.pw` (v0.0.25+) |
| Content | `content` | Yes | Default: `images` |
| Nodes | `nodes` | No | Default: all nodes |
| Enable | `disable` | No | Default: enabled |
| Volume Name Prefix | `nimble_vnprefix` | No | Default: `pve` |
| Pool Name | `nimble_pool_name` | No | Default: array's default pool |
| Folder | `nimble_folder` | No | Default: root folder |
| Initiator Group | `nimble_initiator_group` | No | Default: auto-created from IQN |
| Volume Collection | `nimble_volume_collection` | No | Default: none |
| Discovery Portals | `nimble_iscsi_discovery_ips` | No | Comma-separated list, merged with API-discovered portals |
| Discovery Override | `nimble_iscsi_discovery_override` | No | Default: off. Use only the configured portals, skip the Nimble subnets API |
| Session Token TTL | `nimble_token_ttl` | No | Default: 3600 |
| Debug Level | `nimble_debug` | No | Default: 0 |
| Verify TLS Certificate | `nimble_check_ssl` | No | Default: disabled (0) |
| Auto iSCSI Discovery | `nimble_auto_iscsi_discovery` | No | Default: enabled (1) |
| IOPS Limit (new volumes) | `nimble_limit_iops` | No | Default: -1 (unlimited); minimum 256 |
| Throughput Limit MB/s | `nimble_limit_mbps` | No | Default: -1 (unlimited); minimum 1 |
| Legacy Name Fallback | `nimble_legacy_name_fallback` | No | Default: off. Also resolve bare un-prefixed volume names |

## Manual Override

If you prefer to manually edit `/etc/pve/storage.cfg`:

```ini
nimble: nimble1
	nimble_address 10.0.0.100
	username admin
	nimble_vnprefix pve
	content images
	nodes pve1,pve2,pve3
```

Password should be placed in `/etc/pve/priv/storage/nimble1.pw` (v0.0.25+) for cluster-wide security.

## Troubleshooting

### Edit button does nothing

- Check browser console for JavaScript errors
- Verify `/usr/share/pve-manager/js/NimbleEdit.js` exists
- Verify `/usr/share/pve-manager/index.html.tpl` contains `<script ... src="/pve2/js/NimbleEdit.js"></script>`
- Hard-refresh the browser (`Ctrl+F5` or `Cmd+Shift+R`)
- If `index.html.tpl` was modified externally, manually re-run the injection:
  ```bash
  sed -i 's|</head>|    <script type="text/javascript" src="/pve2/js/NimbleEdit.js"></script>\n  </head>|' /usr/share/pve-manager/index.html.tpl
  systemctl restart pveproxy.service
  ```

### Nimble not in Add dropdown

- Same troubleshooting steps as "Edit button does nothing"
- Verify `PVE.Utils.storageSchema.nimble` is defined (open browser console and type `PVE.Utils.storageSchema.nimble`)

### pve-manager upgrades overwrite `index.html.tpl`

- The package registers a **dpkg file trigger** (`debian/triggers`) on `/usr/share/pve-manager/index.html.tpl`: whenever a `pve-manager` upgrade replaces the template, `postinst` runs again in `triggered` mode and re-injects the script tag automatically — no manual step needed
- If the tag is ever missing anyway (e.g. the template was edited by hand outside dpkg), re-inject manually:
  ```bash
  dpkg-reconfigure libpve-storage-nimble-perl
  # or
  apt-get install --reinstall libpve-storage-nimble-perl
  ```

### Password not saved on Edit

- The password field shows `********` as a placeholder (this is normal)
- If you **clear** the field (leave it empty), the existing password is kept
- If you **type a new password**, it replaces the existing password
- Password is stored in `/etc/pve/priv/storage/<id>.pw` (replicated across the cluster via `pmxcfs`)

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                         Web Browser                              │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ PVE.storage.NimbleInputPanel (ExtJS)                       │  │
│  │  • Renders form fields                                     │  │
│  │  • Collects user input                                     │  │
│  │  • Validates fields                                        │  │
│  └───────────────────────────┬──────────────────────────────────┘  │
│                              │ POST /api2/extjs/storage          │
└──────────────────────────────┼──────────────────────────────────┘
                               ▼
┌──────────────────────────────────────────────────────────────────┐
│                      Proxmox VE API                              │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ PVE::API2::Storage                                         │  │
│  │  • Validates input against properties()                   │  │
│  │  • Calls NimbleStoragePlugin->on_add_hook()               │  │
│  │  • Persists to /etc/pve/storage.cfg                       │  │
│  └───────────────────────────┬──────────────────────────────────┘  │
└──────────────────────────────┼──────────────────────────────────┘
                               ▼
┌──────────────────────────────────────────────────────────────────┐
│              NimbleStoragePlugin.pm (Backend)                    │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ • type() → "nimble"                                        │  │
│  │ • plugindata() → content types, sensitive properties       │  │
│  │ • properties() → all nimble_* config keys                  │  │
│  │ • options() → required/optional flags                      │  │
│  │ • on_add_hook() → validate, persist password securely     │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

## References

- `NimbleStoragePlugin.pm`: Backend plugin (defines API and storage operations)
- `www/NimbleEdit.js`: Frontend GUI (ExtJS InputPanel and schema registration)
- `debian/postinst`: Deployment script (injects `<script>` tag, restarts pveproxy)
- `debian/postrm`: Cleanup script (removes `<script>` tag on uninstall)
- `pve-manager/www/manager6/dc/StorageView.js`: Main storage list/Add/Edit dispatcher
- `pve-manager/www/manager6/storage/Base.js`: Base classes for storage panels
- `pve-manager/www/manager6/Utils.js`: Global `storageSchema` registry
