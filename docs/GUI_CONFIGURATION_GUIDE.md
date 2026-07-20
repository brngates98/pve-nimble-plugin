# Exposing Configuration to Proxmox Web UI

This document explains how the Nimble storage plugin integrates with the Proxmox VE Web UI to allow administrators to modify storage settings (like API IPs and Discovery IPs) directly from the dashboard.

## How Proxmox UI Configuration Works

Proxmox VE does **not** auto-generate storage dialogs from the plugin schema. The backend (`properties()` / `options()` in `NimbleStoragePlugin.pm`) defines what the **API** accepts and validates; the form fields shown in the browser come from a hand-written ExtJS panel — that is why this plugin ships `www/NimbleEdit.js`. A new config key therefore needs **both** a backend declaration and a matching field in `NimbleEdit.js` to be editable from the GUI (keys without a GUI field remain settable via `pvesm set`).

### 1. The `properties()` Method
The `properties()` method is the schema source of truth. Any key declared here (and referenced in `options()`) is accepted and validated by the PVE storage API (`pvesm` / `POST /api2/…/storage`).

**Current Implementation in `NimbleStoragePlugin.pm`:**
The plugin defines a `canonical` set of properties. For example:
```perl
nimble_address => {
  description => "HPE Nimble array management IP or DNS name.",
  type        => 'string'
},
nimble_iscsi_discovery_ips => {
  description => "Optional extra iSCSI discovery portals...",
  type        => 'string',
},
```

### 2. The `options()` Method
While `properties()` defines *what* exists, `options()` defines *how* it behaves in the UI (e.g., whether it is optional, fixed, or hidden).

**Example:**
```perl
nimble_address => { fixed => 1 }, # Prevents editing after creation
nimble_pool_name => { optional => 1 }, # Allows the field to be empty
```

---

## How to Add New UI-Configurable Parameters

If you want to add a new setting (e.g., a toggle to disable auto-discovery) that is editable via the Web UI, follow these steps (Steps 1–3 make it work via API/`pvesm`; Step 4 exposes it in the GUI):

### Step 1: Update `properties()`
Add the new key to the `$canonical` hash in the `properties()` method.
```perl
# In NimbleStoragePlugin.pm -> sub properties
$canonical->{ nimble_disable_auto_discovery } = {
    description => "Disable automatic iSCSI portal discovery from Nimble API.",
    type        => 'boolean',
    default     => 'no'
};
```

### Step 2: Update `options()`
Add the key to the `options()` hash to define its editability.
```perl
# In NimbleStoragePlugin.pm -> sub options
nimble_disable_auto_discovery => { optional => 1 },
```

### Step 3: Use the Value in Code
The updated value will now be available in the `$scfg` (storage configuration) hash passed to all plugin methods.
```perl
if ($scfg->{ nimble_disable_auto_discovery } eq 'yes' ) {
    # Skip the API discovery logic
}
```

### Step 4: Add a Field to `www/NimbleEdit.js`
Add a matching ExtJS field to `PVE.storage.NimbleInputPanel` (e.g. a `proxmoxcheckbox` in `advancedColumn2`) so the option appears in the Add/Edit dialog. Without this the option only works via `pvesm set <id> --nimble_disable_auto_discovery yes`.

---

## Troubleshooting UI Visibility

If a property is not appearing in the Web UI, check the following:

1.  **Namespace Collisions**: The plugin has a safety mechanism that deletes properties if another registered plugin (like `pve-purestorage-plugin`) already owns that name. This prevents the Proxmox daemon from crashing. This is why we use the `nimble_` prefix.
2.  **Daemon Restart**: Proxmox loads storage plugins into memory. After modifying `NimbleStoragePlugin.pm`, you must restart the `pvedaemon` and `pveproxy` services for the UI changes to take effect:
    ```bash
    systemctl restart pvedaemon pveproxy
    ```
3.  **Schema Validation**: Ensure the `type` specified in `properties()` (`string`, `integer`, `boolean`) matches the expected input.

## Summary of Configuration Flow

**Web UI Change** → **`pveproxy` (API)** → **`storage.cfg` (Disk)** → **`NimbleStoragePlugin::check_config` (Plugin)** → **Internal `$scfg` hash**.