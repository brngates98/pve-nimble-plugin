# iSCSI Auto-Discovery Flow

This document explains how the Nimble Proxmox plugin discovers iSCSI portals and establishes sessions. This is critical for environments with multiple subnets where only specific portals should be queried.

## Discovery Logic Overview

The plugin uses a tiered approach to find discovery portals. It prioritizes the Nimble API's view of the network over manual configuration or host-side session sniffing.

### 1. Gathering Discovery IPs
The function `get_nimble_iscsi_discovery_ips` (approx. line 1668 in `NimbleStoragePlugin.pm`) determines which IPs to query. The order of precedence is:

1.  **Nimble Subnets API**: It calls `GET /v1/subnets`. For each subnet, it fetches details via `GET /v1/subnets/:id` and extracts the `discovery_ip`. It prefers subnets of type `data`.
2.  **Network Interfaces API (Fallback)**: If subnets return nothing, it calls `GET /v1/network_interfaces`. It filters for interfaces with `nic_type` matching `data`, `iscsi`, or `discovery` and extracts their `ip_list`.
3.  **Manual Configuration**: It appends any IPs provided in the storage configuration key `nimble_iscsi_discovery_ips` (comma-separated list).
4.  **Active Session Supplement (Last Resort)**: If all the above are empty, it scans the host's current iSCSI sessions (`iscsiadm -m session`) and extracts the portal IPs currently in use.

### 2. The Discovery Process (The "Timeout" Point)
Once the list of IPs is gathered, the plugin attempts to find available targets using `iscsi_sendtargets_on_ips` (approx. line 1959).

**The Execution Loop:**
```perl
for my $ip ( @$ips_ref ) {
    # ... untaint and validate IP ...
    eval {
        run_command(
            [ $iscsiadm, '-m', 'discovery', '-t', 'sendtargets', '-p', $disc_ip ],
            # ... options ...
        );
    };
}
```
In this loop, the plugin calls `iscsiadm` for **every single IP** gathered in step 1. If the Nimble array has many subnets/interfaces that are not routable from the current Proxmox node, these calls will result in the **timeouts** seen in the debug logs.

### 3. Targeted Login
After `sendtargets` populates the local `iscsiadm` node database, the plugin does **not** perform a global login. Instead:
1.  It identifies the specific IQN of the volume it needs.
2.  It retrieves only the portals associated with that specific IQN.
3.  It performs a targeted login: `iscsiadm -m node -T <iqn> -p <portal> --login`.

---

## Summary for Feature Implementation

To implement a feature that limits discovery to a specific set of IPs and avoids querying every IP found on the array:

### Target Code Locations
- **`get_nimble_iscsi_discovery_ips`**: This is where the list of IPs is built. You should modify this function to prioritize a "Fixed Discovery IP" list from the config and potentially skip the API-based gathering if a specific list is provided.
- **`iscsi_sendtargets_on_ips`**: This is the loop that generates the timeouts. By limiting the input `ips_ref` in the previous step, this loop will only run for the intended portals.

### Current Logic Path
`status()` / `activate_storage()` $\rightarrow$ `nimble_iscsi_establish_volume_session()` $\rightarrow$ `get_nimble_iscsi_discovery_ips()` $\rightarrow$ `iscsi_sendtargets_on_ips()` $\rightarrow$ `iscsiadm -m discovery`.