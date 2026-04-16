# AI Project Context: PVE Nimble Storage Plugin

**Purpose of this document:** Give an AI (or human) enough context to continue this project without prior conversation. Read this first when resuming work.

---

## 1. What This Project Is

- **Name:** Proxmox VE plugin for **HPE Nimble Storage** over **iSCSI**.
- **Role:** Custom PVE storage backend. Lets Proxmox create, delete, resize, snapshot, and present Nimble volumes as VM disks and LXC root volumes (`rootdir`, raw block, same `vm-<id>-disk-*` naming as VMs).
- **Language:** Perl. Single main module: `NimbleStoragePlugin.pm`, implementing the PVE storage plugin API.
- **Origin:** Cloned structure and patterns from **pve-purestorage-plugin** (Pure Storage array plugin). Same overall flow: REST API to array, token auth, volume CRUD, initiator/ACL mapping, multipath, Proxmox storage interface.

---

## 2. Current Status (as of v0.0.19)

| Area | Status | Notes |
|------|--------|--------|
| **Core plugin** | Implemented | Create/delete/resize/rename volumes, list, status, activate/deactivate, map/unmap |
| **LXC (`rootdir`)** | Implemented | Added as **`rootdir`** in **`plugindata` → `content`** alongside **`images`** and **`none`**; raw block only (no `subvol` format). Same code paths as VM disks; real-array CT smoke test recommended. |
| **list_images / detach** | Implemented | Honors PVE’s `vollist` and `vmid` like RBD: explicit volids (e.g. `unusedN:` in qemu config) are listed for reattach; without `vollist`, results filter by `vmid`. |
| **list_images caching** | Implemented | Volume list cached in `$cache->{nimble}{$storeid}` during a single PVE operation to avoid redundant REST calls. Returns a shallow copy to prevent cache mutation. |
| **ACL on activate (initiator_group set)** | Fixed | `nimble_ensure_volume_acl_for_current_node` used to return immediately when `initiator_group` was set, so **no** access_control_record was created; LUN never presented → timeout waiting for disk. Now ACL is ensured for the configured group as well as for auto `pve-<nodename>`. |
| **Auth** | Implemented | Username/password → POST /v1/tokens → session token; cached under `/etc/pve/priv/nimble/<storeid>.json` |
| **ACL / initiator** | Implemented | **initiator_group** optional: if set, that group by name; if unset, **reuse** first iSCSI group containing this host’s IQN (API order, skip any group with CHAP/`chapuser_id` on initiators), else create `pve-<nodename>`. **access_control_records** on create/activate. |
| **Snapshots** | Implemented | Create, delete, rollback; Nimble snapshots API + volume restore; Veeam snapshot name normalization (`veeam_` → `veeam-`) |
| **Clone from snapshot** | Implemented | Via POST volumes with clone=true, name, base_snap_id (then ACL + optional volume_collection) |
| **Multipath** | Implemented | Device by serial, multipathd add/remove map, block device actions |
| **Multipath alias management** | Implemented | Plugin auto-writes volname→WWID aliases to `/etc/multipath/conf.d/nimble-<storeid>.conf` on `map_volume`, removes on `free_image`, restores on `activate_storage`. WWID cache persisted in `/etc/pve/priv/nimble/<storeid>.wwid.json`. Skips WWIDs already defined in `/etc/multipath.conf` with a warning. |
| **Device discovery** | Implemented | **3-tier fallback:** `/dev/disk/by-id/wwn-0x<api_serial>`, then any `by-id` name containing the API `serial_number` (needed for multipath dm — often no sysfs `device/serial`), then sysfs serial match. |
| **Auto iSCSI discovery** | Implemented | **Default on** for **`auto_iscsi_discovery`** on **activate_storage** (`no`/`0` disables). **`map_volume`** mirrors manual PVE iSCSI (portal + per-volume IQN + LUN 0): portal list = **GET subnets + GET subnets/:id per subnet** (authoritative), then **network_interfaces** fallback, optional **`iscsi_discovery_ips`**, then **tcp session IPs from `iscsiadm`** (last resort); sendtargets + per-target login; **`node.startup=automatic`**; **`iscsiadm -m session --rescan`**; long wait + periodic SCSI rescan; device by **serial**; `multipath -v2`. |
| **Volume import/export** | Implemented | `raw+size` for backup/restore (e.g. Veeam V13+); size rounded up to full MB for odd-sector compatibility |
| **Array snapshot sync** | Implemented | `nimble_sync_array_snapshots` runs from `status()` (throttled to once per 30s per storage). Uses **`GET snapshots`** when the array allows an unfiltered list; otherwise merges **`GET snapshots?vol_id=`** per PVE volume (some firmware returns **400** / **`SM_missing_arg`** without a filter). When filtered rows omit **`vol_name`** / **`creation_time`**, the plugin fills volume identity from fetch context (or **`vol_id`→volume** map) and uses **`nimble_snapshot_effective_creation_time`** for ordering/grouping. If the list still has no time for PVE **snaptime**, **`nimble_hydrate_snapshot_detail`** merges detail responses with **`nimble_merge_snapshot_hash_skip_undef`** (order: **GET `snapshots/:id`**, **`snapshots?id=`**, **GET `volumes/:id`**, then **`snap_collection_id`** → **GET `snapshot_collections/:id`**) so JSON **null** from a weaker response does not wipe **creation_time** from path **GET `snapshots/:id`**. Imports array-created snapshots into PVE VM configs; array snaps get **`nimble<epoch-or-hash>`** keys. **v0.0.19+:** PVE snapshot **`description`** is the Nimble snapshot **`name`**, prefixed by array **volume name** per disk: **`volume: snapshot name`**, joined with **`; `** when one PVE snapshot groups multiple LUNs (deduped if identical). On each sync, existing **`nimble*`** entries still showing the legacy generic **Imported from Nimble array** text (any case) or an empty description are updated to the new format when the array still has that snapshot. **`nimble<suffix>`** snapshot keys use the same epoch as **`snaptime`** when a display epoch (**`$gui`**) exists (else min effective time), so rollback matches hydrated API rows; **`nimble_volume_restore`** / delete / rollback preflight **hydrate** list rows and fall back to **`snaptime`** from **`PVE::QemuConfig`** if the suffix still does not match (legacy configs). **QEMU VMs only;** CT roots skipped (no `LXCConfig` sync). Multi-disk VMs may not group if the array provides no shared timestamp across LUNs. |
| **APIVER 12/13 methods** | Implemented | `volume_qemu_snapshot_method` returns `’storage’` (delegates snapshot management to plugin). `qemu_blockdev_options` returns `host_device` driver spec for mapped block node, `undef` if not yet mapped. `volume_snapshot_info` reverse-maps Nimble snapshot names to PVE snapshot keys. `volume_rollback_is_possible` now preflights volume/snapshot resolvability before returning success. `rename_snapshot` stubs with a clean die. |
| **Debian package** | Present | `libpve-storage-nimble-perl`, debian/*, scripts/build_deb.sh. **`postinst`** **try-restarts** **`pvedaemon`**, **`pvestatd`**, **`pveproxy`**, **`pvescheduler`** — same as [pve-purestorage-plugin `debian/postinst`](https://github.com/kolesa-team/pve-purestorage-plugin/blob/main/debian/postinst) but **without** **`pve-cluster`** (Pure includes cluster; we omit it to avoid long **`apt`** stalls). **`install-pve-nimble-plugin.sh`** uses the same four units. |
| **CI (GitHub Actions)** | Present | checks (unit tests + plugin syntax in Docker), release (tag → build .deb → gh-release) |
| **Unit tests** | Present | test_command_validation.t, test_retry_logic.t, test_token_cache.t, test_nimble_plugin_import_export_guards.t (+ token_cache_test.pl); no live Nimble tests |
| **Real-array testing** | Broad lab pass (informal) | **2026-04 maintainer check** on PVE + real HPE Nimble: volume lifecycle (create/delete/resize/rename), PVE snapshots (create/delete/rollback), clone from snapshot, move disk / delete source, **status**/capacity, multipath + map/unmap, array snapshot sync (**`nimble*`** imports, sparse list rows, **snaptime** after **`GET snapshots/:id`** hydration, **v0.0.19** **`volume: snapshot name`** descriptions). Earlier notes still apply: **rollback (v0.0.15+)** uses **`nimble_volume_prepare_restore_disconnect`** before **`nimble_volume_ensure_offline`**; **move disk** uses **`nimble_remove_volume`** (disconnect, snapshot purge, **DELETE** retry on **409**/**`SM_eperm`**). Not a formal matrix — firmware and topology differ. **LXC `rootdir`:** implemented; exercise on your array if you rely on it. |
| **debian/watch** | Done | Points at `brngates98/pve-nimble-plugin` |

---

## 3. Repo Layout (quick reference)

```
pve-nimble-plugin/
├── NimbleStoragePlugin.pm     # Main plugin (PVE::Storage::Custom::NimbleStoragePlugin)
├── README.md                  # User-facing install/config/docs
├── CONTRIBUTING.md
├── LICENSE
├── docs/
│   ├── README.md              # Documentation index (guides, API, dev docs)
│   ├── 00-SETUP-FULLY-PROTECTED-STORAGE.md  # Step-by-step setup guide (zero to protected storage)
│   ├── AI_PROJECT_CONTEXT.md  # This file (AI/context)
│   ├── API_VALIDATION.md      # Nimble REST API call validation vs HPE docs
│   ├── NIMBLE_API_REFERENCE.md # In-repo extract of HPE REST API 5.1.1.0 (read for endpoint/request/response details)
│   └── STORAGE_FEATURES_COMPARISON.md # Feature and content-type comparison vs NFS, LVM, iSCSI, Ceph RBD
├── .github/workflows/         # release, _deb
├── debian/                    # Package: libpve-storage-nimble-perl
├── scripts/
│   ├── build_deb.sh            # Local Docker build
│   ├── install-pve-nimble-plugin.sh  # Scripted install (single/cluster, APT or .deb)
│   └── deploy-nimble-plugin-pm.sh   # Hot-fix: curl/wget .pm → install → restart; default `REMOTES` pve001+pve003 (override with env); scp+ssh to each (skip if hostname matches)
└── tests/
    ├── run_tests.sh
    ├── unit/*.t               # Perl unit tests
    └── token_cache_test.pl
```

---

## 4. How the Plugin Fits Together

- **Config (storage.cfg):** `address`, `username` (legacy `nimble_user` is merged into `username` in `check_config`), **`password`** (stored **in `storage.cfg`** like TrueNAS **`api_key`** / Pure **`token`**—cluster-replicated), optional `initiator_group`, optional `vnprefix`, `pool_name`, optional **`volume_collection`**, `check_ssl`, `token_ttl`, `debug`, optional **`auto_iscsi_discovery`** (default **on**; **`no`**/**`0`** disables activate-time discovery), optional **`storeid`** (auto-set in **`check_config`**), optional **`content`** (plugin defaults: **`images`**, **`rootdir`**, **`none`**; narrow with e.g. `content images` if you do not want CT roots on that store). **`plugindata → sensitive-properties`**: **`{}`** (empty). **`nimble_api_credentials`** uses **`$scfg->{password}`** first, then priv **`.pw`** files. **`on_add_hook` / `on_update_hook` / `on_update_hook_full`** mirror password changes into **`priv/storage/<storeid>.pw`** (and legacy paths) for compatibility. Do not add undeclared keys to **`properties()`** or PVE fails SectionConfig validation.
- **Nimble API base:** `https://<address>:5392/v1/`. Auth: POST `tokens` with username/password → use `session_token` as `X-Auth-Token` on later requests. List responses may use `data: { items: [ ... ] }`; `nimble_data_as_list` unwraps `items`. Discovery portals: GET **`subnets`** then **GET `subnets/:id` for each row** (merge), collect **`discovery_ip`** (type `data` preferred); fallbacks: **`network_interfaces`** + **`network_interfaces/:id`**, optional **`iscsi_discovery_ips`**, then **`iscsiadm` tcp session IPs** last. Pure plugin differs: API **connections** + no `iscsiadm` in `map_volume` ([pve-purestorage-plugin](https://github.com/kolesa-team/pve-purestorage-plugin)).
- **Volume naming:** `nimble_volname(scfg, volname, [snapname])` = optional prefix + volname (e.g. `vm-100-disk-0`) + optional `.snap-<name>` for snapshots.
- **Key API calls:** volumes (GET/POST/PUT/DELETE), access_control_records (POST/DELETE), snapshots (POST create, GET by name or full list, DELETE), volume restore (POST with base_snap_id), **subnets** / **subnets/:id**, **network_interfaces** / **network_interfaces/:id** (discovery IP fallbacks). **Pure-aligned lifecycle:** `nimble_volume_connection($mode)` mirrors `purestorage_volume_connection` (connect before map, disconnect after unmap). **`nimble_remove_volume`** = **`nimble_volume_prepare_restore_disconnect`** (unmap, iSCSI logout, all ACRs) → local DM cleanup → ACR delete → snapshot purge (multi-round) → **offline** → snapshot purge → **DELETE** (409/**SM_eperm** retry with full prep). Used by **`free_image`** (e.g. move disk “delete source”). **`nimble_resolve_initiator_group_id_no_create`** supports disconnect without creating groups. **`filesystem_path`** optional 4th arg `$storeid` + **`nimble_effective_storeid`** for API login; **`on_update_hook_full`** mirrors **`password`** to priv files (PVE signature: **`$opts`**, **`$delete`**, **`$sensitive`**).
- **Worker password / import child:** **`check_config`** sets **`$opts->{storeid} = $sectionId`**. **`nimble_effective_storeid`** + **`nimble_api_credentials`** / **`nimble_api_call`** (token cache). **`path()`** forwards **`$storeid`** into **`filesystem_path`**. Fallback priv order: **`priv/storage/<storeid>.pw`**, **`.nimble.pw`**, **`priv/nimble/<storeid>.pw`**.
- **Device path:** Volume `serial_number` from API → find block device by serial under `/sys/block/*/device/serial` and `/dev/disk/by-id` → optional multipath by WWID.
- **Taint (`-T`) and `iscsiadm`:** IQNs and portal strings passed to **`run_command` / `iscsiadm`** must be **`nimble_untaint_iscsiadm_scalar`**-laundered; tainted API strings caused silent **`eval {}` failures** and **no iSCSI session** before that helper existed.

---

## 5. Differences from Pure Storage Plugin (reference)

- **Auth:** Nimble = username/password → session_token; Pure = API token → login → x-auth-token (`token` property — avoids clashing with globally registered `password`).
- **PVE property registry:** Do **not** declare `username` / `password` in Nimble’s **`properties()`** — RBD/CIFS already register them globally. List **`username` + `password` in `options()`**. **`plugindata → sensitive-properties`**: **`{}`** — **`password`** lives in **`storage.cfg`** (same trust model as TrueNAS **`api_key`**). Hooks mirror to priv **`.pw`** on add/update. **`pvesm`** uses underscores (`--auto_iscsi_discovery`), not hyphens, for multi-word options.
- **`sub api`:** Use `PVE::Storage::APIVER()` and `PVE::Storage::APIAGE()` with parentheses and `use PVE::Storage ();` — they are `use constant` subs, not `$PVE::Storage::APIVER` (wrong — uninitialized). Bareword `PVE::Storage::APIVER` without `()` fails **strict subs** on Perl 5.36+ (e.g. CI bookworm `perl -c`).
- **ACL:** Nimble = initiator groups + access_control_records (vol_id, initiator_group_id); Pure = host/volume “connections.”
- **API shape:** Nimble = `/v1/` JSON with `data` arrays; Pure = custom filter/params and `items`.
- **Cache:** Nimble = one file per storage (`<storeid>.json`); Pure = per-array (`<storeid>_arrayN.json`) for Active Cluster.

---

## 5.1 Nimble API reference (for AI / contributors)

**Read `docs/NIMBLE_API_REFERENCE.md`** for in-repo API context loaded from HPE docs. It contains:

- **Source:** [HPE Nimble REST API 5.1.1.0](https://support.hpe.com/docs/display/public/nmtp352en_us/wzk1480348939804.html) (object sets index and operation details).
- **Request/response envelope:** All request bodies and single-object responses use a `data` wrapper (`{ "data": { ... } }`).
- **Object sets used by the plugin:** tokens, initiator_groups, initiators, volumes, access_control_records, snapshots, pools — with Create/Read/Update/Delete and RPC (e.g. volumes **restore**: `POST v1/volumes/id/actions/restore` with `id`, `base_snap_id`).
- **Key parameters:** e.g. tokens (username, password → session_token), volume create (name, size, optional pool_name), initiator_groups create (name, access_protocol, iscsi_initiators array), pools read (capacity, usage, usage_valid).
- **Links** to the official HPE pages for each object set and operation.

Use this file when implementing or validating API calls instead of relying only on external docs.

**Optional adjunct:** The official [HPE Nimble Python SDK](https://github.com/hpe-storage/nimble-python-sdk) ([docs](https://hpe-storage.github.io/nimble-python-sdk/)) targets the same REST API. It can help when designing a dedicated Perl client (endpoint coverage, naming, workflows); this plugin currently calls the API directly from `NimbleStoragePlugin.pm`.

---

## 6. What Might Need Work (when resuming)

- **Snapshot rollback (array `online` + cgroup / initiators)** — Rollback uses `nimble_volume_restore`: **`nimble_volume_prepare_restore_disconnect`** on the target, then **`nimble_volume_ensure_offline`**, which retries with **`force: true`** on **409** / **`SM_vol_has_connections`** when a **sibling volume in the same Nimble cgroup** still has sessions (error cites another **`vol=`**). Then restore → online. See `docs/API_VALIDATION.md` § Snapshot rollback.
- **Nimble API quirks:** Response shapes (e.g. list vs single object, pagination) may need adjustment per Nimble firmware; error codes/messages might need better handling.
- **API audit (2026-04):** Full audit of all REST call patterns completed. One **Must Fix** bug applied: `volume_snapshot_info` was not URI-escaping `vol_id` in the query string (line ~3049; now fixed). Key **Verify on array** items: (1) `POST initiator_groups` with inline `iscsi_initiators` accepted on target firmware; (2) `multi_initiator` field on volume create/PUT; (3) `snapshots?vol_id=` and `access_control_records?vol_id=` filter query params supported; (4) `arrays` response field names (`usable_capacity_bytes`, `available_bytes`). **Improvement** (not blocking): `nimble_volume_connection` disconnect path fetches all ACRs — could use filtered query. See `docs/API_VALIDATION.md` for full findings.
- **Status/capacity:** `status()` uses **GET pools** (with **GET pools/:id** when list rows lack **`capacity`**), derives **`free_space` + `usage`** when **`capacity`** is still zero (see **`NIMBLE_API_REFERENCE.md` §9** for compression caveat), **`pool_name`** matches **`nimble_pool_identifier_matches_want`** (**`name` | `search_name` | `full_name` | `pool_name`** on array-style rows), then **GET arrays** fallback filtered with **`nimble_array_matches_status_pools`**. Arrays fallback sets **`$used = $au`** whenever **`$at > 0`**. API failure returns **`(0,0,0,0)`** (inactive), not a fake 1-byte total.
- **Changelog:** `_deb.yml` generates `debian/changelog` from git tags and history. Pushing a tag runs the release workflow and produces the .deb.

---

## 6.1 Releases (for AI or human)

When creating a release, **always**:

1. **Verify the next release version** – Run `git tag -l 'v*' | sort -V` and use the **next sequential** version (e.g. after v0.0.6 the next is v0.0.7). Do not jump versions (e.g. do not go to v1.0.0 unless that is the explicit next version).
2. **Include release notes** – Create or update `.github/release-notes-<tagname>.md` (e.g. `.github/release-notes-v0.0.7.md`). The release workflow copies this file to the GitHub release body; without it the release has only a generic title.
3. **Never skip versions** – Use the immediate next version from existing tags. Match the filename and package version (e.g. tag `v0.0.7` → notes file `release-notes-v0.0.7.md`, package version `0.0.7-1`).

See `.cursor/rules/releases.mdc` for the full release rule.

---

## 7. How to Run Things (for AI or human)

- **Unit tests:** `./tests/run_tests.sh` or `perl -I. tests/unit/<file>.t`. Requires Perl, Test::More, JSON (and JSON::XS for token_cache_test.pl).
- **Array API unknowns (live):** `./scripts/nimble_api_unknowns_probe.sh` — prompts for URL/username/password (like **`nimble_capacity_api_probe.sh`**), auto-picks a probe volume id (volumes list or ACR **`vol_id`**), runs **docs/API_VALIDATION.md** section 5 checks; **structured JSON** to a file (default timestamped name; path optional); optional mutating flags in script header.
- **Snapshot sync debug (live):** `./scripts/nimble_snapshot_sync_diagnostic.sh` — read-only JSON dump: **`volumes`**, bulk vs per-**`vol_id`** **`GET snapshots`**, per-volume snapshot samples (including **`snap_collection_id`**), **`snapshot_time_detail_probe`** (**`GET snapshots/:id`**, **`snapshots?id=`**, **`GET volumes/:id`**, optional **`snapshot_collections/:id`**) to see where **`creation_time`** / **`last_modified`** appear vs list rows, and **`sync_vol_name_analysis`**. Use when array-created snapshots do not appear in Proxmox or PVE snap times look wrong.
- **Lint:** perltidy with `.perltidyrc`; markdownlint with `.markdownlint.json`. Run locally as needed (CI currently runs tests + plugin syntax checks).
- **Build .deb:** `./scripts/build_deb.sh` (Docker, Debian bookworm) or CI on tag push.
- **Install (manual):** Copy `NimbleStoragePlugin.pm` to `/usr/share/perl5/PVE/Storage/Custom/` on a PVE node and restart pvedaemon/pveproxy. Or install the built .deb.
- **Scripted install:** `scripts/install-pve-nimble-plugin.sh` — single-node or cluster-wide (all nodes via SSH), from APT repo or a specific GitHub release .deb; supports `--dry-run`, `--yes`, `--all-nodes` (same pattern as Blockbridge’s get script).
- **Add storage (example):**  
  `pvesm add nimble <id> --address https://<nimble> --username <u> --password <p> --initiator_group <name> --content images,rootdir`

---

## 8. Conventions to Keep

- Follow the same structure and style as **pve-purestorage-plugin** (Perl style, error messages "Error :: ...", debug with `$DEBUG`, token cache under `/etc/pve/priv/`).
- Storage type is `nimble`; shared storage is declared with `push @PVE::Storage::Plugin::SHARED_STORAGE, 'nimble'`.
- Debian package name: `libpve-storage-nimble-perl`; plugin file goes to `PVE/Storage/Custom/NimbleStoragePlugin.pm`.

---

*Last updated: v0.0.19 — array-import snapshot descriptions (**`volume: snapshot name`**); broad informal real-array validation note (2026-04). Update this file when you make significant changes or when status/next steps change.*
