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
| PUT `volumes/:id`                  | size, name, **online**, optional **`force`** with **`online`** (forcibly offline per HPE). **`nimble_volume_ensure_offline`**: plain **`online:false`**, then **409**/**`SM_vol_has_connections`**/**`SM_http_conflict`** → **`online:false` + `force:true`**. Restore/delete prep use **`nimble_volume_ensure_offline`**. | Update                                                                                                                                                                                                       | OK                                                                                                       |
| DELETE `volumes/:id`               | Delete volume; **preceded by** offline (via **`nimble_volume_ensure_offline`**), snapshot + ACR cleanup (avoids 409 on rollback/migration) | Delete                                                                                                                                                                                                       | OK                                                                                                       |
| POST `volumes/:id/actions/restore` | id, base_snap_id in body; **requires volume offline** on array (see **Snapshot rollback** below)    | Restore: Request id (restored volume), base_snap_id (mandatory)                                                                                                                                              | **Fixed** to use `actions/restore` and body with id + base_snap_id.                                      |
| **Access control**                 |                                                                                                    |                                                                                                                                                                                                              |                                                                                                          |
| GET `access_control_records`       | List all; plugin filters by vol_id and initiator_group_id (for ensure-ACL-on-activate / migration) | Read                                                                                                                                                                                                         | OK                                                                                                       |
| POST `access_control_records`      | vol_id, initiator_group_id                                                                         | Create: vol_id, initiator_group_id                                                                                                                                                                           | OK                                                                                                       |
| DELETE `access_control_records/:id` | Per-id delete: **`nimble_volume_connection`** (disconnect), **`nimble_delete_access_control_records_for_volume_id`** (restore prep + **`nimble_remove_volume`**), migration helpers | Delete                                                                                                                                                                                                       | OK                                                                                                       |
| **Snapshots**                      |                                                                                                    |                                                                                                                                                                                                              |                                                                                                          |
| POST `snapshots`                   | vol_id, name                                                                                       | Create: vol_id, name (mandatory)                                                                                                                                                                             | OK                                                                                                       |
| GET `snapshots?name=...`           | List by name, match by `name`                                                                      | Read with query param `name`                                                                                                                                                                                 | OK                                                                                                       |
| GET `snapshots`                    | Multiple callers: (1) `nimble_snapshot_delete` + `volume_snapshot_info` use `?vol_id=` filter (URI-escaped). (2) `nimble_delete_snapshots_for_volume_id` uses `?vol_id=` filter with fallback to all — performance gap reduced to fallback path only. (3) `nimble_sync_array_snapshots` fetches all (intentional — needs cross-volume view for group detection). | Read                                                                                                                                                                                                         | OK; `vol_id` filter supported as a query param (verify on array — fallback to unfiltered GET is present). **Fixed**: `volume_snapshot_info` now URI-escapes `vol_id` (was bare interpolation). |
| DELETE `snapshots/:id`             | Delete by id                                                                                       | Delete                                                                                                                                                                                                       | OK                                                                                                       |
| **Pools**                          |                                                                                                    |                                                                                                                                                                                                              |                                                                                                          |
| GET `pools`, GET `pools/:id`       | capacity, usage_valid, usage, free_space                                                           | Read: list may omit capacity; plugin **`status()`** GETs **`pools/:id`** when capacity is missing, derives capacity from **free_space + usage** when needed (see **`NIMBLE_API_REFERENCE.md` §9** for a known compression edge case). **`pool_name`** in storage config matches **`nimble_pool_identifier_matches_want`**: pool **`name`**, **`search_name`**, **`full_name`**, or (on array-style rows) **`pool_name`**. Arrays fallback uses the same helper plus **`pool_id`** / **`pool_name`** cross-link to pools in **`@use`**. |
| GET `arrays`                       | usable_capacity_bytes, available_bytes, usage, pool_name, usage_valid, vol_usage_bytes, snap_usage_bytes | Read: optional fallback for **`status()`** when pool list yields no capacity.                                                                                                                               | **Verify on array**: field names `usable_capacity_bytes`, `available_bytes`, `vol_usage_bytes`, `snap_usage_bytes` are not formally listed in the HPE REST API 5.1.1.0 inline reference — confirm against actual array response. Only used as a fallback when pools yield no capacity. |
| GET `access_control_records` (deactivate path) | `nimble_volume_connection` disconnect: fetches ALL ACRs (no `vol_id` filter), then filters client-side by `vol_id` + `ig_id` | Read — `vol_id` query param not verified | **Improvement**: could mirror `nimble_volume_has_acl_for_ig` — filtered `access_control_records?vol_id=<id>` with fallback to full list — to reduce payload on large arrays. Current all-ACR fetch is correct; not a correctness issue. |
| **`multi_initiator` on volumes**   | PUT `volumes/:id { multi_initiator: true }` in `nimble_ensure_volume_multi_initiator`; also sent on POST volumes (create/clone) | Python SDK `volumes.py` documents this field; not listed in HPE REST 5.1.1.0 inline Create table | **Verify on array**: field accepted by some firmware versions. Non-fatal warn on failure already in place — does not block activation. |
| **Clone from snapshot**            | POST `volumes` with clone=true, name, base_snap_id (then add ACL)                                  | Create doc: clone + name + base_snap_id for clone. Restore is for existing volume only.                                                                                                                      | **Fixed**: clone_image now uses nimble_clone_from_snapshot (POST volumes clone=true) instead of restore. |
| **Snapshot create**                | volname then snap_name in call                                                                     | —                                                                                                                                                                                                            | **Fixed**: volume_snapshot now passes (volname, snap) to nimble_snapshot_create.                         |
| **Volume collections**             | GET `volume_collections?name=...`                                                                  | Read with query param `name`                                                                                                                                                                                 | OK (optional: add volumes to collection via PUT volumes/:id volcoll_id).                                 |
| **Subnets (auto iSCSI)**           | GET `subnets`, GET `subnets/:id`, GET `network_interfaces/:id`                                     | For every subnet from GET `subnets`, plugin GET `subnets/:id` and merges into the row (authoritative `discovery_ip` / `type`). Collect portals: type `data` preferred, then any `discovery_ip`; if none: `network_interfaces` (+ `:id` if `ip_list` empty), optional `iscsi_discovery_ips`, then live `iscsiadm` tcp session IPs (last). Serial match: normalized / substring for API vs sysfs. |
| **Volume import/export (raw+size)** | N/A (plugin stream)                                                                                | PVE format: 8-byte little-endian size header then raw bytes. Used for backup/restore (e.g. Veeam V13+).                                                                                                     | OK: volume_import, volume_export, volume_import_formats, volume_export_formats; size rounded up (size_bytes_to_mb) for odd-sector compatibility. |
| **Array snapshot sync**            | `nimble_sync_array_snapshots`: GET `snapshots` (all), GET `volumes` (for vol→vmid map), then writes PVE VM config entries for array-created snaps not already tracked by PVE. Runs from `status()` throttled to once per 30s. | GET snapshots, GET volumes                                                                                                                                                                                    | OK; fetches all snapshots (no vol_id filter) by design — needs cross-volume view to detect consistent snapshot groups across a VM's disks. |
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
| `subnets` | `subnets.py` | Discovery portals: **GET subnets** plus **GET subnets/:id** per subnet (merged); feeds **`activate_storage`** and **`map_volume`** (unless `auto_iscsi_discovery` is **`no`**/**`0`** for activate only). |

**Host-side commands (not in the Python SDK):** `iscsiadm` (discovery, login), `multipath` / `multipathd`, `blockdev`, and SCSI host rescan are **Linux / open-iscsi / multipath-tools**—appropriate for a PVE storage plugin and unrelated to the Nimble HTTPS client. Under **`perl -T`**, IQNs and portal arguments passed to **`iscsiadm`** must be **untainted** (`nimble_untaint_iscsiadm_scalar`); otherwise **`run_command` dies** and callers that wrap in **`eval`** leave **no iSCSI session** without a clear log line. **Session checks** use **`iscsiadm -m session`** only and match the IQN in stdout; do **not** use **`iscsiadm -m session -T …`** on typical open-iscsi builds—**`-T`/`--targetname` is for node mode**, and session mode rejects it with *option '-' is not allowed/supported*. Portal strings from **`iscsiadm -m node`** may include a **TPGT** suffix (`host:3260,0`); the plugin strips trailing **`,N`** before **sendtargets** / **login -p**. The `%cmd` table also lists `kpartx` and `dmsetup` for parity with the Pure plugin pattern (validated when present on the node).

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

### Snapshot rollback (`volume_snapshot_rollback` → `nimble_volume_restore`)

- **Array requirement:** Restore fails with **409** / **`SM_vol_not_offline_on_restore`** if the volume is still **online** on the Nimble array. PUT **`online=false`** can fail with **409** / **`SM_vol_has_connections`** when **any** initiator session applies to the volume’s **cgroup** (error may reference a **sibling** **`vol=`**, not the volume you are offlining). Host disconnect on the target LUN alone may be insufficient.
- **Plugin sequence:** (0) **`nimble_volume_prepare_restore_disconnect`** for the target — **`unmap_volume`**, **`nimble_iscsi_logout_volume_local`**, all ACRs for that volume. (1) **`nimble_volume_ensure_offline`** — PUT **`{ online: false }`**; on **409** / **`SM_vol_has_connections`** / **`SM_http_conflict`**, PUT **`{ online: false, force: true }`** (HPE **forcibly offline**). If PUT succeeds but GET still shows online, forced PUT is attempted once. (2) POST **`volumes/:id/actions/restore`**. (3) **`nimble_volume_ensure_online`**. (4) Failed restore: same bring-online / warning behavior as before.
- **Multi-node / cgroup caveat:** Another **cluster node** or **sibling LUN** in the same Nimble cgroup can still block a **non-forced** offline; **forced** offline is disruptive but matches admin-driven destroy/rollback. If the array rejects even **`force`**, resolve sessions on the other host or Nimble UI.
- **Shared helpers:** **`nimble_volume_detail`**, **`nimble_volume_ensure_offline`**, **`nimble_volume_ensure_online`**. **`nimble_offline_volume_and_delete_snapshots`** (used from **`nimble_remove_volume`**) deletes snapshots (multi-round), offlines the volume, then deletes snapshots again for stragglers.

### Volume delete (`free_image`, e.g. storage move with “delete source disk”)

- **`nimble_remove_volume`:** **`nimble_volume_prepare_restore_disconnect`** first (unmap, **`nimble_iscsi_logout_volume_local`**, all ACRs) so the array does not still see host connections; local multipath/LVM cleanup; ACR delete (idempotent); **`nimble_offline_volume_and_delete_snapshots`**; **`DELETE volumes/:id`**. On **409** / **`SM_http_conflict`** / **`SM_eperm`**, sleep, repeat disconnect + offline/snapshot purge, **`DELETE`** again.
- **`nimble_delete_snapshots_for_volume_id`:** Up to **5** rounds, newest-first by **`creation_time`**, **1** s between rounds; warns on failed snapshot **DELETE** (silent failures previously left snapshots and caused **`SM_eperm`** on volume **DELETE**).
- **Create / clone:** **`nimble_ensure_initiator_group_id`** runs inside the same **`eval`** as ACL (and optional volume collection) so a failure there triggers **`nimble_volume_offline_then_delete_best_effort`** and does not orphan a newly created volume on the array.

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

- **Paths:** **tokens** (POST `…/v1/tokens` only; handled inside `nimble_api_call` before other methods—callers never pass `'POST', 'tokens'` as a path), initiator_groups, **initiators** (GET — used with GET initiator_groups to classify CHAP and IQN membership when picking a reusable group), volumes, volumes/:id, volumes/:id/actions/restore, access_control_records, access_control_records/:id, snapshots, snapshots/:id, pools, volume_collections, subnets, subnets/:id, network_interfaces, network_interfaces/:id.
- **Methods:** POST (tokens, initiator_groups, volumes, access_control_records, snapshots), GET (all list/read), PUT (volumes/:id for size, name, volcoll_id, **online**), DELETE (volumes/:id, snapshots/:id, access_control_records/:id).
- **Request bodies:** All POST/PUT bodies are sent as `{ data => $body }`; GET/DELETE use no body.
- **Clone vs restore:** Restore = POST volumes/:id/actions/restore (overwrite existing volume). Clone = POST volumes with clone=true, name, base_snap_id (new volume). Plugin uses both correctly.
- **Python SDK:** The same paths map to [HPE’s nimble-python-sdk](https://github.com/hpe-storage/nimble-python-sdk) `v1/api/*.py` modules (see **Cross-check** table above); `volumes.py` implements `restore` and documents `clone` / `base_snap_id` on create, matching this plugin.

### Comparison with Pure Storage plugin (Proxmox-side logic)

Reference: [kolesa-team/pve-purestorage-plugin](https://github.com/kolesa-team/pve-purestorage-plugin).

| Area                    | Pure                                                            | Nimble                                                                                   | Notes                                                                                                                     |
| ----------------------- | --------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| **activate_volume**     | `purestorage_volume_connection(1)` then map_volume             | **`nimble_volume_connection(1)`** then map_volume (optional `$hints` like Pure)            | Same call order; Nimble connect = ensure ACR for storage’s initiator group.                                              |
| **deactivate_volume**   | unmap_volume, then disconnect from host                         | unmap_volume, then **`nimble_volume_connection(0)`** (DELETE ACR for this storage’s initiator group, same ig as connect) | Mirrors `purestorage_volume_connection` off; Nimble model is one ACR per (volume, initiator_group). |
| **map_volume**          | get path/wwid, scsi_scan_new, wait for path to exist, multipath | get serial from API, scsi_scan_new, wait by serial for device, then path/wwid, multipath | Nimble uses serial-based wait so it works after migration when device is not yet present.                                 |
| **free_image / delete** | deactivate_volume, then local DM cleanup, disconnect **all** hosts, destroy volume | `free_image` → **`nimble_remove_volume`**: **`nimble_volume_prepare_restore_disconnect`**, optional **cleanup_lvm** / **multipath -f**, **DELETE all ACRs**, snapshot purge → **offline** → snapshot purge, **DELETE** volume (**409** / **`SM_eperm`** retry with full prep). |
| **rename_volume**       | unmap, rename on array                                          | Same                                                                                     | Aligned.                                                                                                                  |
| **Snapshots**           | snap_volume_create(vol, snap); volume_restore for rollback and clone; snap_volume_delete | nimble_snapshot_create; nimble_volume_restore (rollback); nimble_clone_from_snapshot; nimble_snapshot_delete | Same behavior: create snapshot on array, rollback = in-place restore, clone = new volume from snapshot, delete snapshot. Nimble uses separate clone API (POST volumes clone=true) vs Pure’s “restore to new name.” |
| **Block/multipath**     | block_device_slaves, block_device_action, multipathd add/remove | Same pattern                                                                             | Aligned.                                                                                                                  |

Conclusion: Proxmox-side flow matches Pure where the model applies: activate → array-side access then map; deactivate → unmap then per-host disconnect when safe; free_image → deactivate then remove volume with full disconnect-all and destroy. Nimble uses ACRs instead of Pure connections; per-node `pve-<nodename>` ACLs are removed on deactivate, shared groups are not.

### Audit notes (plugin and docs)

- **Response handling:** All list/read responses that are iterated now use `nimble_data_as_list()` so that both array and single-object `data` from the API are handled.
- **volume_size_info:** Uses `nimble_get_volume_info`; returns size/used; `used` from `vol_usage_compressed_bytes` or `size` fallback. Consistent with API.
- **Error handling:** 401 triggers token cache clear and one retry; API errors die with message; ensure-ACL treats “already exists”/“duplicate” as success.
- **Migration:** Ensure-ACL on activate (per-node initiator_group only) plus serial-based wait in map_volume ensures the target node can activate after live migration. **Shared-storage live migrate** does not create a new volume or snapshot on the array for the disk: the same Nimble volume/LUN is mapped on the target host over iSCSI (Pure does the same logical thing via API “connections” + pre-discovered portals; neither plugin clones the disk for a normal HA migrate).

### Code inventory (`nimble_api_call` and login)

Every HTTPS object-set call goes through `nimble_api_call` with `v1/` paths above; **POST tokens** uses the same JSON envelope but `LWP` posts to `$base/v1/tokens` inside `nimble_api_call` before other requests. **iSCSI** (`iscsiadm`) is host-side only — not Nimble REST — and is documented in the host-side paragraph of this file.

**Volume `online` (array-side export):** besides direct PUT `volumes/:id` in a few places, the plugin centralizes rollback/delete-prep offline/online in **`nimble_volume_detail`**, **`nimble_volume_ensure_offline`** (optional **`force`** on second PUT for **409** / **`SM_vol_has_connections`** / cgroup siblings), and **`nimble_volume_ensure_online`** (all use GET/PUT **`volumes/:id`** via **`nimble_api_call`**).

**Every `DELETE volumes/:id` path prepares offline/ACL:** (1) **`nimble_remove_volume`** / **`free_image`** — **`nimble_volume_prepare_restore_disconnect`**, then **`nimble_offline_volume_and_delete_snapshots`** (snapshots → offline → snapshots), then **DELETE** (with retry + full prep on **409** / **`SM_eperm`**). (2) **Failed create** / **failed clone** — **`nimble_volume_offline_then_delete_best_effort`** (**offline** then **DELETE** in **`eval`**; cleanup path).

---

## 5. Explicit unknowns (manual / probe)

These behaviors are **not fully specified** in the in-repo HPE extract or vary by firmware. Validate on your array before relying on them in production.

| Unknown | Recommended test |
| ------- | ---------------- |
| Does **POST initiator_groups** with **iscsi_initiators** inline work on firmware 5.x? (HPE doc also documents **POST initiators** separately.) | Test on target array. If rejected, add **POST v1/initiators** `{ initiator_group_id, access_protocol, label, iqn }` after group creation. |
| Does **GET snapshots?vol_id=** return a filtered list or all snapshots? | GET on array with multiple volumes; compare counts to an unfiltered list and to a client-side filter. |
| Does **GET access_control_records?vol_id=** work as a filter? | GET filtered vs unfiltered; compare counts. |
| Does **multi_initiator** appear in **GET v1/volumes/:id** after **PUT**? | GET after PUT; confirm the field is present and true if set. |
| What fields does **GET v1/arrays** expose? Are **usable_capacity_bytes** / **available_bytes** always present? | GET on target array; inspect keys and types (plugin uses these in **status()** fallback). |
| Does **force: true** on **PUT volumes/:id** with **online: false** match expectations across 4.x vs 5.x? | Validate on the specific firmware you run (depends on cgroup / initiator sessions). |

**Automated helper (read-only by default):** `./scripts/nimble_api_unknowns_probe.sh` — prompts for API URL, username, and password (same as **`nimble_capacity_api_probe.sh`**), runs the checks above, and **writes one structured JSON object to a file** (default `nimble-unknowns-probe-<UTC-timestamp>.json` in the current directory; optional path argument overrides). Prints `Wrote <path>` on stderr. Login failures emit JSON on stderr and exit non-zero. Probe **volume id** is chosen automatically (first **`GET volumes`** row, else first **`vol_id`** from **`GET access_control_records`**); **`NIMBLE_VOL_ID`** only if you want a specific volume. Other optional env: **`VERIFY_SSL=1`**, **`RUN_INLINE_IG_PROBE=1`**, **`RUN_MULTI_INITIATOR_PUT=1`**. Report **`meta.volume_id_source`** is `volumes_list`, `access_control_records`, `environment`, or `none`. See script header for details.

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
