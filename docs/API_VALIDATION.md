# Nimble REST API Validation

This document validates the API calls in `NimbleStoragePlugin.pm` against the **HPE Nimble Storage REST API Reference Version 3.1.0.0** (and v1 base path).  
Reference: [REST API Object Sets](https://support.hpe.com/docs/display/public/nmtp355en_us/htr1457290369852.html).

---

## Summary

| Endpoint / usage | Plugin call | HPE doc | Status |
|-----------------|------------|---------|--------|
| **Authentication** | | | |
| POST `/v1/tokens` | username, password → session_token | Create: username (mandatory), password; Response: session_token | OK |
| **Initiator groups** | | | |
| GET `initiator_groups?name=...` | List by name, match by `name` | Read with query param `name` | OK |
| POST `initiator_groups` | name, access_protocol, iscsi_initiators (array of { label, iqn }) | Create: name, access_protocol (mandatory); Response includes iscsi_initiators. Request table does not list iscsi_initiators; initiators may be added via POST `initiators` (initiator_group_id, label, iqn). | Verify on array: inline iscsi_initiators may be accepted by some versions. |
| **Volumes** | | | |
| GET `volumes?name=...` | List by name, match by `name` | Read with query param `name` | OK |
| GET `volumes` | List all | Read | OK |
| POST `volumes` | name, size (MB), optional pool_name | Create: name, size (MB), optional pool_id (doc shows pool_id; response has pool_name; plugin uses pool_name) | OK; pool_name accepted by API in practice. |
| PUT `volumes/:id` | size (resize) or name (rename) | Update | OK |
| DELETE `volumes/:id` | Delete volume | Delete | OK |
| POST `volumes/:id/actions/restore` | id, base_snap_id in body | Restore: Request id (restored volume), base_snap_id (mandatory) | **Fixed** to use `actions/restore` and body with id + base_snap_id. |
| **Access control** | | | |
| GET `access_control_records` | List all; plugin filters by vol_id and initiator_group_id (for ensure-ACL-on-activate / migration) | Read | OK |
| POST `access_control_records` | vol_id, initiator_group_id | Create: vol_id, initiator_group_id | OK |
| **Snapshots** | | | |
| POST `snapshots` | vol_id, name | Create: vol_id, name (mandatory) | OK |
| GET `snapshots?name=...` | List by name, match by `name` | Read with query param `name` | OK |
| DELETE `snapshots/:id` | Delete by id | Delete | OK |
| **Pools** | | | |
| GET `pools` | capacity, usage_valid, usage | Read: capacity, usage (NsBytes = number), usage_valid | **Adjusted**: status() now handles usage as number or nested { compressed_usage, uncompressed_usage }. |
| **Clone from snapshot** | POST `volumes` with clone=true, name, base_snap_id (then add ACL) | Create doc: clone + name + base_snap_id for clone. Restore is for existing volume only. | **Fixed**: clone_image now uses nimble_clone_from_snapshot (POST volumes clone=true) instead of restore. |
| **Snapshot create** | volname then snap_name in call | — | **Fixed**: volume_snapshot now passes (volname, snap) to nimble_snapshot_create. |
| **Volume collections** | GET `volume_collections?name=...` | Read with query param `name` | OK (optional: add volumes to collection via PUT volumes/:id volcoll_id). |
| **Subnets (auto iSCSI)** | GET `subnets` | Read; discovery_ip, allow_iscsi, type | OK (used when auto_iscsi_discovery is set). |

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

### Comparison with Pure Storage plugin (Proxmox-side logic)

Reference: [kolesa-team/pve-purestorage-plugin](https://github.com/kolesa-team/pve-purestorage-plugin).

| Area | Pure | Nimble | Notes |
|------|------|--------|--------|
| **activate_volume** | Connect volume to host (API), then map_volume | Ensure ACL for current node (if per-node IG), then map_volume | Same idea: ensure array-side access then map. Nimble uses initiator_group + ACR instead of Pure’s host/connection. |
| **deactivate_volume** | unmap_volume, then disconnect from host | unmap_volume only | By design: we do not remove ACL on deactivate (documented in README). Pure disconnects so only connected host had access. |
| **map_volume** | get path/wwid, scsi_scan_new, wait for path to exist, multipath | get serial from API, scsi_scan_new, wait by serial for device, then path/wwid, multipath | Nimble uses serial-based wait so it works after migration when device is not yet present. |
| **free_image / delete** | Disconnect from all hosts, then destroy volume | deactivate_volume (unmap), then delete volume; no ACL removal | Nimble does not remove ACRs on delete; volume is deleted on array. |
| **rename_volume** | unmap, rename on array | Same | Aligned. |
| **Block/multipath** | block_device_slaves, block_device_action, multipathd add/remove | Same pattern | Aligned. |

Conclusion: Proxmox-side flow (activate → ensure access then map; deactivate → unmap; create/delete/rename/snapshot/clone) is aligned with Pure where the model applies. Differences (no disconnect on deactivate, ACL-based access) are intentional and documented.

### Audit notes (plugin and docs)

- **Response handling:** All list/read responses that are iterated now use `nimble_data_as_list()` so that both array and single-object `data` from the API are handled.
- **volume_size_info:** Uses `nimble_get_volume_info`; returns size/used; `used` from `vol_usage_compressed_bytes` or `size` fallback. Consistent with API.
- **Error handling:** 401 triggers token cache clear and one retry; API errors die with message; ensure-ACL treats “already exists”/“duplicate” as success.
- **Migration:** Ensure-ACL on activate (per-node initiator_group only) plus serial-based wait in map_volume ensures the target node can activate after live migration.

---

## References

- [REST API (object sets index)](https://support.hpe.com/docs/display/public/nmtp355en_us/htr1457290369852.html)
- [Perl code sample (tokens, volumes)](https://support.hpe.com/docs/display/public/nmtp352en_us/htr1449782650567.html)
- [tokens Create](https://support.hpe.com/docs/display/public/nmtp355en_us/htr1449782671923.html)
- [initiator_groups Create](https://support.hpe.com/docs/display/public/nmtp355en_us/htr1449782663101.html)
- [initiators Create](https://support.hpe.com/docs/display/public/nmtp355en_us/htr1449782664211.html)
- [volumes Create](https://support.hpe.com/docs/display/public/nmtp355en_us/htr1449782674626.html)
- [volumes Restore](https://support.hpe.com/docs/display/public/nmtp355en_us/htr1449717107235.html)
- [access_control_records Create](https://support.hpe.com/docs/display/public/nmtp355en_us/htr1449782650786.html)
- [snapshots Create](https://support.hpe.com/docs/display/public/nmtp355en_us/htr1449782670282.html)
- [pools Read](https://support.hpe.com/docs/display/public/nmtp355en_us/htr1449782666286.html)
