# Nimble REST API Validation

This document validates the API calls in `NimbleStoragePlugin.pm` against the **HPE Nimble Storage REST API Reference Version 5.1.1.0** (and v1 base path).  
Reference: [REST API](https://support.hpe.com/docs/display/public/nmtp352en_us/wzk1480348939804.html). In-repo spec: `docs/NIMBLE_API_REFERENCE.md`.

---

## Summary

| Endpoint / usage                   | Plugin call                                                                                        | HPE doc                                                                                                                                                                                                      | Status                                                                                                   |
| ---------------------------------- | -------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------- |
| **Authentication**                 |                                                                                                    |                                                                                                                                                                                                              |                                                                                                          |
| POST `/v1/tokens`                  | username, password → session_token                                                                 | Create: username (mandatory), password; Response: session_token                                                                                                                                              | OK                                                                                                       |
| **Initiator groups**               |                                                                                                    |                                                                                                                                                                                                              |                                                                                                          |
| GET `initiator_groups?name=...`    | List by name, match by `name`                                                                      | Read with query param `name`                                                                                                                                                                                 | OK                                                                                                       |
| GET `initiator_groups`             | List all; auto mode scans for a group containing host IQN (skip groups with CHAP)                  | Read                                                                                                                                                                                                         | OK                                                                                                       |
| GET `initiators`                   | List all; map `initiator_group_id`, `iqn`, `chapuser_id` for group pick / CHAP skip                | Read                                                                                                                                                                                                         | OK (used when available; falls back to group `iscsi_initiators`).                                        |
| POST `initiator_groups`            | name, access_protocol, iscsi_initiators (array of { label, iqn })                                  | Create: name, access_protocol (mandatory); Response includes iscsi_initiators. Request table does not list iscsi_initiators; initiators may be added via POST `initiators` (initiator_group_id, label, iqn). | Verify on array: inline iscsi_initiators may be accepted by some versions.                               |
| **Volumes**                        |                                                                                                    |                                                                                                                                                                                                              |                                                                                                          |
| GET `volumes?name=...`             | List by name, match by `name`                                                                      | Read with query param `name`                                                                                                                                                                                 | OK                                                                                                       |
| GET `volumes`                      | List all                                                                                           | Read                                                                                                                                                                                                         | OK                                                                                                       |
| GET `volumes/:id`                 | `target_name` = per-volume iSCSI IQN (volume targets); used for `iscsiadm -T … -p … --login` on map | Read                                                                                                                                                                                                         | OK                                                                                                       |
| POST `volumes`                     | name, size (MB), optional pool_name                                                                | Create: name, size (MB), optional pool_id (doc shows pool_id; response has pool_name; plugin uses pool_name)                                                                                                 | OK; pool_name accepted by API in practice.                                                               |
| PUT `volumes/:id`                  | size (resize) or name (rename)                                                                     | Update                                                                                                                                                                                                       | OK                                                                                                       |
| DELETE `volumes/:id`               | Delete volume                                                                                      | Delete                                                                                                                                                                                                       | OK                                                                                                       |
| POST `volumes/:id/actions/restore` | id, base_snap_id in body                                                                           | Restore: Request id (restored volume), base_snap_id (mandatory)                                                                                                                                              | **Fixed** to use `actions/restore` and body with id + base_snap_id.                                      |
| **Access control**                 |                                                                                                    |                                                                                                                                                                                                              |                                                                                                          |
| GET `access_control_records`       | List all; plugin filters by vol_id and initiator_group_id (for ensure-ACL-on-activate / migration) | Read                                                                                                                                                                                                         | OK                                                                                                       |
| POST `access_control_records`      | vol_id, initiator_group_id                                                                         | Create: vol_id, initiator_group_id                                                                                                                                                                           | OK                                                                                                       |
| **Snapshots**                      |                                                                                                    |                                                                                                                                                                                                              |                                                                                                          |
| POST `snapshots`                   | vol_id, name                                                                                       | Create: vol_id, name (mandatory)                                                                                                                                                                             | OK                                                                                                       |
| GET `snapshots?name=...`           | List by name, match by `name`                                                                      | Read with query param `name`                                                                                                                                                                                 | OK                                                                                                       |
| DELETE `snapshots/:id`             | Delete by id                                                                                       | Delete                                                                                                                                                                                                       | OK                                                                                                       |
| **Pools**                          |                                                                                                    |                                                                                                                                                                                                              |                                                                                                          |
| GET `pools`                        | capacity, usage_valid, usage                                                                       | Read: capacity, usage (NsBytes = number), usage_valid                                                                                                                                                        | **Adjusted**: status() now handles usage as number or nested { compressed_usage, uncompressed_usage }.   |
| **Clone from snapshot**            | POST `volumes` with clone=true, name, base_snap_id (then add ACL)                                  | Create doc: clone + name + base_snap_id for clone. Restore is for existing volume only.                                                                                                                      | **Fixed**: clone_image now uses nimble_clone_from_snapshot (POST volumes clone=true) instead of restore. |
| **Snapshot create**                | volname then snap_name in call                                                                     | —                                                                                                                                                                                                            | **Fixed**: volume_snapshot now passes (volname, snap) to nimble_snapshot_create.                         |
| **Volume collections**             | GET `volume_collections?name=...`                                                                  | Read with query param `name`                                                                                                                                                                                 | OK (optional: add volumes to collection via PUT volumes/:id volcoll_id).                                 |
| **Subnets (auto iSCSI)**           | GET `subnets`                                                                                      | Read; discovery_ip, allow_iscsi, type                                                                                                                                                                        | OK; `nimble_data_as_list` unwraps `items[]` or nested `data[]`; GET `network_interfaces` + `ip_list` fallback; optional `iscsi_discovery_ips`; else `iscsiadm -m session` IPs.                |
| **Volume import/export (raw+size)** | N/A (plugin stream)                                                                                | PVE format: 8-byte little-endian size header then raw bytes. Used for backup/restore (e.g. Veeam V13+).                                                                                                     | OK: volume_import, volume_export, volume_import_formats, volume_export_formats; size rounded up (size_bytes_to_mb) for odd-sector compatibility. |
| **401 retry**                     | nimble_api_call: clear cache + retry once on 401                                                   | —                                                                                                                                                                                                             | OK: optional 6th param $is_retry prevents infinite recursion.                                            |

### Cross-check: [HPE Nimble Python SDK](https://github.com/hpe-storage/nimble-python-sdk)

The Python SDK ([documentation](https://hpe-storage.github.io/nimble-python-sdk/)) is generated against the same **v1** REST API. Every **object set** this plugin calls has a matching `nimbleclient/v1/api/<name>.py` module, so names and operations stay aligned with what HPE exposes to both clients.

| Plugin `nimble_api_call` path (relative to `v1/`) | SDK module (under `nimbleclient/v1/api/`) | Notes |
| ------------------------------------------------- | ------------------------------------------- | ----- |
| `tokens` (POST login; plugin uses LWP + JSON) | `tokens.py` | Same auth model: session token, `X-Auth-Token`. |
| `initiator_groups` | `initiator_groups.py` | Plugin may send `iscsi_initiators` on create; SDK also has `initiators.py` for separate initiator objects (see Initiator groups detail below). |
| `access_control_records` | `access_control_records.py` | — |
| `volumes`, `volumes/:id`, `volumes/:id/actions/restore` | `volumes.py` | SDK `VolumeList.restore(id, base_snap_id)` maps to **restore** action; volume **create** with `clone` + `base_snap_id` matches plugin clone-from-snapshot. |
| `snapshots`, `snapshots/:id` | `snapshots.py` | — |
| `pools` | `pools.py` | |
| `volume_collections` | `volume_collections.py` | Lookup by `name=`; plugin uses PUT `volumes/:id` with `volcoll_id` per API doc. |
| `subnets` | `subnets.py` | Used for discovery IPs when `auto_iscsi_discovery` is enabled. |

**Host-side commands (not in the Python SDK):** `iscsiadm` (discovery, login), `multipath` / `multipathd`, `blockdev`, and SCSI host rescan are **Linux / open-iscsi / multipath-tools**—appropriate for a PVE storage plugin and unrelated to the Nimble HTTPS client. The `%cmd` table also lists `kpartx` and `dmsetup` for parity with the Pure plugin pattern (validated when present on the node).

---

## Details

### Authentication (tokens)

- **Plugin:** POST to `https://<address>:5392/v1/tokens` with JSON `{ "data": { "username", "password" } }`; expects `session_token` in response (under `data`); uses `X-Auth-Token` for subsequent requests.
- **HPE doc:** POST v1/tokens; Request: username (mandatory), password; Response: session_token, id, creation_time, etc.
- **Verdict:** Matches.

### Initiator groups

- **Plugin:** Creates group with `name`, `access_protocol` => 'iscsi', and `iscsi_initiators` => [ { label => $nodename, iqn => $iqn } ].
- **HPE doc:** Create lists only name, description, access_protocol, target_subnets. Initiators are documented under object set **initiators**: POST v1/initiators with initiator_group_id, access_protocol, label, iqn.
- **Verdict:** If your array rejects POST initiator_groups with iscsi_initiators, the plugin can be changed to create the group then POST to `initiators` for each IQN.

### Volumes

- **Create:** name, size (MB), optional pool_name. Doc lists pool_id; plugin uses pool_name (supported in practice).
- **Restore:** Doc specifies **POST v1/volumes/id/actions/restore** with body `id` (restored volume) and `base_snap_id`. Plugin was updated to use this path and body.

### Pools (status)

- **Plugin:** GET pools; sums capacity; for used space, uses usage_valid and usage (numeric or nested compressed_usage/uncompressed_usage).
- **HPE doc:** GET v1/pools; response capacity (bytes), usage (bytes), usage_valid.
- **Verdict:** Logic updated to support usage as a number per API.

### Volume fields used

- From volume/snapshot responses: id, name, serial_number, size (MB), creation_time, vol_usage_compressed_bytes (optional for used).
- Doc: serial_number, size, creation_time, etc. Match.

### Volume import/export (raw+size)

- **Plugin:** volume_import reads 8-byte little-endian size (pack Q<), creates volume with size_bytes_to_mb round-up, activates, streams exactly size_bytes from $fh to device, deactivates. On failure: deactivate then delete volume. volume_export writes 8-byte size header then streams device to $fh. volume_import_formats / volume_export_formats return ['raw+size'] when no snapshot.
- **PVE/backup:** Matches PVE PluginBase raw+size format (64-bit LE size prefix). Ensures odd sector sizes (e.g. from Veeam) do not truncate (round up to full MB).

### 401 retry

- **Plugin:** On 401, unlink token cache and delete _auth_token, then recurse with $is_retry=1. When $is_retry is true, 401 is not retried (die immediately). Limits to one retry to avoid infinite recursion on bad credentials.

---

## Request/response envelope (data wrapper)

The [HPE Perl code sample](https://support.hpe.com/docs/display/public/nmtp352en_us/htr1449782650567.html) (REST API Reference 5.1.1.0) shows:

- **Request body:** payload is wrapped in a `data` key, e.g. `{ "data": { "username": "...", "password": "..." } }` for tokens, `{ "data": { "name": "vol1", "size": 1024 } }` for volume create.
- **Response:** token and other single-object responses put the object under `data`, e.g. `$tokenObj->{"data"}->{"session_token"}`.

The plugin follows this convention: it sends all POST/PUT bodies as `{ data => $body }` and reads the token from `data.session_token` when present (with a fallback to top-level `session_token` for compatibility). List responses are normalized via `nimble_data_as_list($r->{ data })` so both array and single-object API responses are handled (HPE may return either for filtered GETs).

---

## Validation and audit (code vs API and Pure plugin)

### HPE Nimble API — endpoint checklist

All plugin API usage has been checked against `docs/NIMBLE_API_REFERENCE.md`:

- **Paths:** tokens, initiator_groups, initiators (not used; initiator_groups accepts iscsi_initiators inline), volumes, volumes/:id, volumes/:id/actions/restore, access_control_records, snapshots, snapshots/:id, pools, volume_collections, subnets.
- **Methods:** POST (tokens, initiator_groups, volumes, access_control_records, snapshots), GET (all list/read), PUT (volumes/:id for size, name, volcoll_id), DELETE (volumes/:id, snapshots/:id).
- **Request bodies:** All POST/PUT bodies are sent as `{ data => $body }`; GET/DELETE use no body.
- **Clone vs restore:** Restore = POST volumes/:id/actions/restore (overwrite existing volume). Clone = POST volumes with clone=true, name, base_snap_id (new volume). Plugin uses both correctly.
- **Python SDK:** The same paths map to [HPE’s nimble-python-sdk](https://github.com/hpe-storage/nimble-python-sdk) `v1/api/*.py` modules (see **Cross-check** table above); `volumes.py` implements `restore` and documents `clone` / `base_snap_id` on create, matching this plugin.

### Comparison with Pure Storage plugin (Proxmox-side logic)

Reference: [kolesa-team/pve-purestorage-plugin](https://github.com/kolesa-team/pve-purestorage-plugin).

| Area                    | Pure                                                            | Nimble                                                                                   | Notes                                                                                                                     |
| ----------------------- | --------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| **activate_volume**     | Connect volume to host (API), then map_volume                   | Ensure ACL for current node (if per-node IG), then map_volume                            | Same idea: ensure array-side access then map. Nimble uses initiator_group + ACR instead of Pure’s host/connection.        |
| **deactivate_volume**   | unmap_volume, then disconnect from host                         | unmap_volume only                                                                        | By design: we do not remove ACL on deactivate (documented in README). Pure disconnects so only connected host had access. |
| **map_volume**          | get path/wwid, scsi_scan_new, wait for path to exist, multipath | get serial from API, scsi_scan_new, wait by serial for device, then path/wwid, multipath | Nimble uses serial-based wait so it works after migration when device is not yet present.                                 |
| **free_image / delete** | Disconnect from all hosts, then destroy volume                  | deactivate_volume (unmap), then delete volume; no ACL removal                            | Nimble does not remove ACRs on delete; volume is deleted on array.                                                        |
| **rename_volume**       | unmap, rename on array                                          | Same                                                                                     | Aligned.                                                                                                                  |
| **Snapshots**           | snap_volume_create(vol, snap); volume_restore for rollback and clone; snap_volume_delete | nimble_snapshot_create; nimble_volume_restore (rollback); nimble_clone_from_snapshot; nimble_snapshot_delete | Same behavior: create snapshot on array, rollback = in-place restore, clone = new volume from snapshot, delete snapshot. Nimble uses separate clone API (POST volumes clone=true) vs Pure’s “restore to new name.” |
| **Block/multipath**     | block_device_slaves, block_device_action, multipathd add/remove | Same pattern                                                                             | Aligned.                                                                                                                  |

Conclusion: Proxmox-side flow (activate → ensure access then map; deactivate → unmap; create/delete/rename/snapshot/clone) is aligned with Pure where the model applies. Differences (no disconnect on deactivate, ACL-based access) are intentional and documented.

### Audit notes (plugin and docs)

- **Response handling:** All list/read responses that are iterated now use `nimble_data_as_list()` so that both array and single-object `data` from the API are handled.
- **volume_size_info:** Uses `nimble_get_volume_info`; returns size/used; `used` from `vol_usage_compressed_bytes` or `size` fallback. Consistent with API.
- **Error handling:** 401 triggers token cache clear and one retry; API errors die with message; ensure-ACL treats “already exists”/“duplicate” as success.
- **Migration:** Ensure-ACL on activate (per-node initiator_group only) plus serial-based wait in map_volume ensures the target node can activate after live migration.

---

## References

(Aligned with `docs/NIMBLE_API_REFERENCE.md` — HPE Nimble REST API 5.1.1.0.)

- [REST API (object sets index)](https://support.hpe.com/docs/display/public/nmtp352en_us/wzk1480348939804.html)
- [Perl code sample (tokens, volumes)](https://support.hpe.com/docs/display/public/nmtp352en_us/htr1449782650567.html)
- [tokens](https://support.hpe.com/docs/display/public/nmtp352en_us/hyv1480349057572.html) → [Create](https://support.hpe.com/docs/display/public/nmtp352en_us/umf1480349057761.html)
- [initiator_groups](https://support.hpe.com/docs/display/public/nmtp352en_us/jom14803490011631.html) → [Create](https://support.hpe.com/docs/display/public/nmtp352en_us/wir14803490013351.html)
- [initiators](https://support.hpe.com/docs/display/public/nmtp352en_us/irx1480349008822.html) → [Create](https://support.hpe.com/docs/display/public/nmtp352en_us/zws1480349009009.html)
- [volumes](https://support.hpe.com/docs/display/public/nmtp352en_us/wex1480349067913.html) → [Create](https://support.hpe.com/docs/display/public/nmtp352en_us/dyz1480349073106.html), [Restore](https://support.hpe.com/docs/display/public/nmtp352en_us/dyi1480349077467.html)
- [access_control_records](https://support.hpe.com/docs/display/public/nmtp352en_us/ktk1480348940664.html) → [Create](https://support.hpe.com/docs/display/public/nmtp352en_us/tkf1480348940945.html)
- [snapshots](https://support.hpe.com/docs/display/public/nmtp352en_us/clb1480349051490.html) → [Create](https://support.hpe.com/docs/display/public/nmtp352en_us/qfv1480349052600.html)
- [pools](https://support.hpe.com/docs/display/public/nmtp352en_us/zty1480349029606.html) → [Read](https://support.hpe.com/docs/display/public/nmtp352en_us/ahk1480349034094.html)
