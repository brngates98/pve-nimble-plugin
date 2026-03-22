# HPE Nimble Storage REST API Reference (in-repo extract)

This file is an in-repo extract of the **HPE Nimble Storage REST API Reference Version 5.1.1.0** for AI and contributor context. Full docs: [REST API](https://support.hpe.com/docs/display/public/nmtp352en_us/wzk1480348939804.html).

**Base URL:** `https://<array_mgmt_ip>:5392/v1/`  
**Auth:** POST `tokens` with `data.username` and `data.password` → response `data.session_token`; use `X-Auth-Token` on subsequent requests.

**Related (same REST API, different language):** HPE’s [Nimble Python SDK](https://github.com/hpe-storage/nimble-python-sdk) ([documentation](https://hpe-storage.github.io/nimble-python-sdk/)) maps object sets (volumes, snapshots, initiator_groups, subnets, tokens, etc.) to Python clients. This repo does not use that SDK; it is a useful reference if you extract or mirror the API as a Perl module—compare paths, payloads, and `data` envelopes against this file and `docs/API_VALIDATION.md`.

---

## 1. Request/response envelope (data wrapper)

All request bodies and single-object responses use a **`data`** wrapper:

- **Request:** `{ "data": { ...payload... } }`
- **Response:** `{ "data": { ...object... } }` or `{ "data": [ ...array... ] }`

Example (tokens Create):

```json
// Request
{ "data": { "username": "admin", "password": "admin" } }

// Response
{ "data": { "session_token": "1c1cfbac...", "id": "19000000...", "username": "admin", "creation_time": 1426802065, ... } }
```

---

## 2. Object sets index (REST API 5.1.1.0)

| Object set | Description | RESTful ops | RPC actions |
|------------|-------------|-------------|-------------|
| **access_control_records** | Records for access to volumes/snapshots | create, read, delete | |
| **initiator_groups** | Groups of initiators for ACL | create, read, update, delete | suggest_lun, validate_lun |
| **initiators** | Initiators in initiator groups | create, read, delete | |
| **pools** | Storage pools | create, read, update, delete | merge |
| **snapshots** | Snapshots for a volume | create, read, update, delete | bulk_create |
| **tokens** | User session tokens | create, read, delete | report_user_details |
| **volumes** | Volumes (LUNs) | create, read, update, delete | abort_move, bulk_move, bulk_set_dedupe, get_allocated_bitmap, get_unshared_bitmap, move, **restore** |

Other sets in full docs: active_directory_memberships, alarms, application_servers, application_categories, arrays, audit_log, chap_users, disks, shelves, master_key, events, fibre_channel_*, folders, groups, jobs, network_*, performance_policies, protection_*, protocol_endpoints, replication_partners, snapshot_collections, software_versions, space_domains, subnets, user_groups, users, versions, volume_collections.

---

## 3. tokens

**Create — POST v1/tokens**

- **Request (data):** `username` (mandatory), `password`, optional `app_name`, `source_ip`.
- **Response (data):** `id`, `session_token`, `username`, `app_name`, `source_ip`, `creation_time`, `last_modified`.
- **JSON request example:** `{ "data": { "username": "admin", "password": "admin" } }`
- **Normal response:** 201.

---

## 4. initiator_groups

**Create — POST v1/initiator_groups**

- **Request (data):** `name` (mandatory), `access_protocol` (mandatory; 'iscsi' or 'fc'), optional `description`, `host_type`, `target_subnets`, **`iscsi_initiators`**, **`fc_initiators`**, `app_uuid`.
- **iscsi_initiators:** Array of `{ "label": "...", "iqn": "...", "ip_address": "..." }`. Either `iqn` or `ip_address` required with `label`.
- **fc_initiators:** Array of `{ "wwpn": "...", "alias": "..." }`; `wwpn` required.
- **Response (data):** `id`, `name`, `full_name`, `search_name`, `access_protocol`, `iscsi_initiators`, `fc_initiators`, `creation_time`, `last_modified`, etc.
- **Normal response:** 201.

---

## 5. initiators

**Create — POST v1/initiators**

- **Request (data):** `access_protocol` (mandatory), `initiator_group_id` (mandatory), optional `label`, `iqn`, `ip_address` (iSCSI), `alias`, `wwpn` (FC).
- **Response (data):** `id`, `access_protocol`, `initiator_group_id`, `initiator_group_name`, `label`, `iqn`, `ip_address`, etc.
- **Normal response:** 201, 202.

---

## 6. volumes

**Create — POST v1/volumes**

- **Request (data):** `name` (mandatory), `size` (mandatory for create, MB), optional `description`, `perfpolicy_id`, `reserve`, `warn_level`, `limit`, `snap_*`, `online`, `pool_id`, `read_only`, `block_size`, `clone`, `base_snap_id`, `agent_type`, `cache_pinned`, `encryption_cipher`, `app_uuid`, `folder_id`, `metadata`, etc. Plugin uses `pool_name` (accepted in practice); API doc lists `pool_id`.
- **Response (data):** `id`, `name`, `full_name`, `size`, `serial_number`, **`target_name`** (iSCSI IQN or FC WWNN for the volume target), `pool_name`, `pool_id`, `creation_time`, `last_modified`, etc.
- **Normal response:** 201, 202.

**Restore — POST v1/volumes/id/actions/restore**

- **Request (data):** `id` (mandatory; volume to restore), `base_snap_id` (mandatory).
- **Normal response:** 200.

**Read — GET v1/volumes**, GET v1/volumes?name=...  
**Update — PUT v1/volumes/id** (e.g. `size`, `name`)  
**Delete — DELETE v1/volumes/id**

---

## 7. access_control_records

**Create — POST v1/access_control_records**

- **Request (data):** `vol_id` (required for volume/snapshot), `initiator_group_id`, optional `apply_to` ('volume'|'snapshot'|'both'|'pe'|'vvol_*'), `chap_user_id`, `lun`, `pe_id`, `snap_id`, `pe_ids`.
- **Response (data):** `id`, `apply_to`, `vol_id`, `vol_name`, `initiator_group_id`, `initiator_group_name`, `lun`, `creation_time`, etc.
- **Normal response:** 201, 202.

---

## 8. snapshots

**Create — POST v1/snapshots**

- **Request (data):** `name` (mandatory), `vol_id` (mandatory), optional `description`, `online`, `writable`, `app_uuid`, `metadata`, `agent_type`.
- **Response (data):** `id`, `name`, `vol_id`, `vol_name`, `size`, `serial_number`, `creation_time`, `last_modified`, etc.
- **Normal response:** 201, 202.

**Read — GET v1/snapshots**, GET v1/snapshots?name=...  
**Delete — DELETE v1/snapshots/id**

---

## 9. pools

**Read — GET v1/pools**

- **Response (data):** Array of pool objects. Key fields: `id`, `name`, **`capacity`** (bytes), **`usage`** (bytes; NsBytes), **`usage_valid`**, `free_space`, `savings_*`, `snap_count`, `vol_count`, etc.
- **Normal response:** 200.

---

## 9.1 Networking (management and iSCSI discovery IPs)

These endpoints are not used by the plugin today but are useful for automation (e.g. auto iSCSI discovery) or for displaying management vs discovery IPs.

**GET v1/network_interfaces**

- **Response (data):** Array of per-array network interfaces.
- **Key fields:** `id`, `name`, **`ip_list`** (list of IPs on this interface), **`nic_type`** (interface role/type), `controller_id`, `controller_name`, `link_status`, `link_speed`, `mac`, `mtu`, `slot`, `port`, `array_id`, `array_name_or_serial`.
- Use `nic_type` and `ip_list` to identify management vs data/iSCSI interfaces (exact `nic_type` values are array/OS-dependent; see Nimble CLI `ip --list` for Type: management, discovery, data, support).
- **Normal response:** 200.

**GET v1/subnets** and **GET v1/subnets/:id**

- **List response (data):** May be **summary rows** (`id`, `name` only) on some firmware; use **GET v1/subnets/:id** for full fields.
- **Key fields:** `id`, `name`, **`type`** (e.g. `'mgmt'`, `'data'`, `'mgmt,data'`), **`discovery_ip`** (address used for iSCSI discovery on this subnet), **`allow_iscsi`**, `network`, `netmask`, `vlan_id`, `mtu`, `failover`, `netzone_type`, `creation_time`, `last_modified`.
- For **iSCSI discovery IPs:** GET subnets (and **GET subnets/:id** if the list lacks `discovery_ip`); use each subnet’s **`discovery_ip`** where **`type` contains `data`** (e.g. `mgmt,data`) for `iscsiadm -m discovery -t sendtargets -p <discovery_ip>`. The plugin’s **fallback** pass uses any subnet that has a `discovery_ip` if none match `type` ~ data.
- For **management:** The management IP is the one you already use for the API (the `address` in storage config). To list it from the API, use subnets with `type` containing `'mgmt'` (and use the subnet’s `discovery_ip` or similar, if documented) or use **network_interfaces** and pick the interface whose `nic_type` indicates management.
- **Normal response:** 200.

**Summary for “show management and discovery IPs”**

| Goal | API call | Use |
|------|----------|-----|
| iSCSI discovery IPs | GET v1/subnets, GET v1/subnets/:id | Prefer `type` containing `data` + `discovery_ip`; list may need per-id GET for full fields. |
| All interface IPs (mgmt + data) | GET v1/network_interfaces | Use `ip_list` and `nic_type` per interface to show management vs discovery/data. |
| Management IP | Already known | It’s the `address` you use for the API. Optionally confirm via subnets (type mgmt) or network_interfaces. |

---

**Plugin use:** When storage option `auto_iscsi_discovery` is enabled (and for portal lists used during volume map), the plugin calls **GET v1/subnets**, **GET v1/subnets/:id** for any row missing `discovery_ip`, then prefers subnets whose **`type` contains `data`** with a non-empty **`discovery_ip`**. If that yields none, it falls back to any subnet with `discovery_ip`, then **network_interfaces**, manual **iscsi_discovery_ips**, and **iscsiadm** session IPs.

## 10. Plugin-relevant endpoints summary

| What | Method | Path | Body (inside `data`) |
|------|--------|------|----------------------|
| Login | POST | v1/tokens | username, password |
| List initiator groups | GET | initiator_groups?name=... | — |
| Create initiator group | POST | initiator_groups | name, access_protocol, iscsi_initiators |
| List volumes | GET | volumes or volumes?name=... | — |
| Create volume | POST | volumes | name, size, optional pool_name |
| Update volume | PUT | volumes/:id | size, name, or volcoll_id (to add/remove from volume collection) |
| Delete volume | DELETE | volumes/:id | — |
| List volume collections | GET | volume_collections or volume_collections?name=... | — |
| Restore volume | POST | volumes/:id/actions/restore | id, base_snap_id |
| Create ACL | POST | access_control_records | vol_id, initiator_group_id |
| Create snapshot | POST | snapshots | vol_id, name |
| List snapshots | GET | snapshots?name=... | — |
| Delete snapshot | DELETE | snapshots/:id | — |
| List pools | GET | pools | — |
| Get iSCSI discovery IPs (auto_iscsi_discovery) | GET | subnets, subnets/:id | — |

---

## 11. Official doc links (5.1.1.0)

- [REST API (object sets index)](https://support.hpe.com/docs/display/public/nmtp352en_us/wzk1480348939804.html)
- [Perl code sample (tokens, volumes)](https://support.hpe.com/docs/display/public/nmtp352en_us/htr1449782650567.html)
- [tokens](https://support.hpe.com/docs/display/public/nmtp352en_us/hyv1480349057572.html) → [Create](https://support.hpe.com/docs/display/public/nmtp352en_us/umf1480349057761.html)
- [initiator_groups](https://support.hpe.com/docs/display/public/nmtp352en_us/jom14803490011631.html) → [Create](https://support.hpe.com/docs/display/public/nmtp352en_us/wir14803490013351.html)
- [initiators](https://support.hpe.com/docs/display/public/nmtp352en_us/irx1480349008822.html) → [Create](https://support.hpe.com/docs/display/public/nmtp352en_us/zws1480349009009.html)
- [volumes](https://support.hpe.com/docs/display/public/nmtp352en_us/wex1480349067913.html) → [Create](https://support.hpe.com/docs/display/public/nmtp352en_us/dyz1480349073106.html), [Restore](https://support.hpe.com/docs/display/public/nmtp352en_us/dyi1480349077467.html)
- [access_control_records](https://support.hpe.com/docs/display/public/nmtp352en_us/ktk1480348940664.html) → [Create](https://support.hpe.com/docs/display/public/nmtp352en_us/tkf1480348940945.html)
- [snapshots](https://support.hpe.com/docs/display/public/nmtp352en_us/clb1480349051490.html) → [Create](https://support.hpe.com/docs/display/public/nmtp352en_us/qfv1480349052600.html)
- [pools](https://support.hpe.com/docs/display/public/nmtp352en_us/zty1480349029606.html) → [Read](https://support.hpe.com/docs/display/public/nmtp352en_us/ahk1480349034094.html)
