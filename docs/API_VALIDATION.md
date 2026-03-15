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
| POST `access_control_records` | vol_id, initiator_group_id | Create: vol_id, initiator_group_id | OK |
| **Snapshots** | | | |
| POST `snapshots` | vol_id, name | Create: vol_id, name (mandatory) | OK |
| GET `snapshots?name=...` | List by name, match by `name` | Read with query param `name` | OK |
| DELETE `snapshots/:id` | Delete by id | Delete | OK |
| **Pools** | | | |
| GET `pools` | capacity, usage_valid, usage | Read: capacity, usage (NsBytes = number), usage_valid | **Adjusted**: status() now handles usage as number or nested { compressed_usage, uncompressed_usage }. |
| **Clone from snapshot** | POST `volumes` with clone=true, name, base_snap_id (then add ACL) | Create doc: clone + name + base_snap_id for clone. Restore is for existing volume only. | **Fixed**: clone_image now uses nimble_clone_from_snapshot (POST volumes clone=true) instead of restore. |
| **Snapshot create** | volname then snap_name in call | — | **Fixed**: volume_snapshot now passes (volname, snap) to nimble_snapshot_create. |

---

## Details

### Authentication (tokens)

- **Plugin:** POST to `https://<address>:5392/v1/tokens` with JSON `{ username, password }`; expects `session_token` in response; uses `X-Auth-Token` for subsequent requests.
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

The plugin follows this convention: it sends all POST/PUT bodies as `{ data => $body }` and reads the token from `data.session_token` when present (with a fallback to top-level `session_token` for compatibility). List responses are already read via `$r->{ data }` (array or object).

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
