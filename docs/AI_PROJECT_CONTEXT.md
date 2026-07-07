# AI Project Context: PVE Nimble Storage Plugin

Read this first when resuming work. **Operators:** use [README.md](../README.md) and [00-SETUP-FULLY-PROTECTED-STORAGE.md](00-SETUP-FULLY-PROTECTED-STORAGE.md). **API details:** [NIMBLE_API_REFERENCE.md](NIMBLE_API_REFERENCE.md), [API_VALIDATION.md](API_VALIDATION.md).

---

## What this is

- Proxmox VE storage plugin for **HPE Nimble** over **iSCSI** (REST API v1, port **5392**).
- **One Nimble volume per disk** — QEMU `images` and LXC `rootdir` (raw block).
- **Code:** `NimbleStoragePlugin.pm` (`PVE::Storage::Custom::NimbleStoragePlugin`), Perl; patterns from [pve-purestorage-plugin](https://github.com/kolesa-team/pve-purestorage-plugin).

---

## Status (v0.0.22+)

### Works (informal lab + field use; not a formal matrix)

- Volume CRUD, resize (array PUT + host iSCSI/multipath rescan), rename, list/status, map/unmap, activate/deactivate.
- Initiator groups + ACLs; optional `initiator_group` or auto `pve-<nodename>`.
- PVE snapshots: create, delete, rollback (array restore); clone from snapshot.
- Multipath (serial discovery, alias files under `conf.d/nimble-<storeid>.conf`).
- Auto iSCSI discovery (default on): subnets API → sendtargets → login each **portal** not already in session; one 60s throttle shared by activate_storage and status(). Login scoping is two-layer: only the `(portal, iqn)` records each sendtargets call reports (never the host's whole iscsiadm node DB), **and** only Nimble vendor IQNs (`nimble_iscsi_iqn_is_nimble_target`) — a foreign portal in the IP list can't get its targets logged in. Session-derived portal IPs are a last-resort fallback only (they can belong to other vendors' arrays). Per-volume IQN login on map when ACL adds a new target.
- Multipath alias register/deregister skip the write + `multipathd reconfigure` when the WWID is already correct/absent (was firing unconditionally on every map/unmap), and the WWID cache (shared cluster-wide via `/etc/pve/priv`) is now guarded by `PVE::Cluster::cfs_lock_storage` to avoid cross-node lost updates.
- `raw+size` import/export (e.g. Veeam V13+).
- Array snapshot **import** into QEMU VM configs (`nimble*` keys, throttled from `status()`).
- APIVER 12–14 (`storage` QEMU snapshots, `qemu_blockdev_options`, `get_identity`, etc.). Note: `volume_resize` `$snapname` and `volume_snapshot_info` `virtual-size` are **APIVER 15** additions per pve-storage ApiChangeLog (earlier release notes said 14); implementing them while reporting 14 is safe (additive).
- Package + CI + unit tests (no live Nimble in CI).

### Partial / needs validation

- **RAM snapshots (vmstate):** `nimble_resolve_block_path_for_volname` activates/maps if `path()` runs before the LUN is visible — confirm on PVE 9.2+ with RAM enabled.
- **LXC `rootdir`:** implemented; exercise on your array if you rely on it.
- **`volume_collection`:** applied on **new** volumes/clones via storage config; normal snapshots OK in testing.

### Not tested / known gaps

- **Synchronous replication** on volume collections (especially **manual** membership in an existing sync-rep collection) — separate from PVE snapshots until field-tested; see README troubleshooting.
- Firmware-specific API shapes (`GET snapshots` without filter, list row sparsity) — see [API_VALIDATION.md](API_VALIDATION.md).
- **Co-install with pve-purestorage-plugin:** safe since v0.0.25 (canonical `nimble_*` property names + deterministic legacy guard; Docker verify script includes a co-install load test). Remaining edge: *unmigrated* legacy config keys (`address`, …) parse under the co-installed plugin's schema for the names it owns — harmless with Pure (identical schemas; ours were copied from Pure), and moot once the config is rewritten with `nimble_*` keys.

---

## Repo layout

```
NimbleStoragePlugin.pm          # main plugin
README.md                       # install, config, troubleshooting
docs/
  AI_PROJECT_CONTEXT.md         # this file
  00-SETUP-FULLY-PROTECTED-STORAGE.md
  NIMBLE_API_REFERENCE.md
  API_VALIDATION.md
  STORAGE_FEATURES_COMPARISON.md
debian/  scripts/  tests/  .github/workflows/
```

---

## How it works (short)

### Config (`storage.cfg`)

Canonical keys are **`nimble_`-prefixed** since v0.0.25: `nimble_address`, `username`, `password`
(**sensitive** since v0.0.24: lives in `/etc/pve/priv/storage/<id>.pw`, not storage.cfg;
`nimble_api_credentials` reads priv file first, legacy cfg line as fallback), optional `port`
(default 5392), `nimble_initiator_group`, `nimble_vnprefix`, `nimble_pool_name`,
`nimble_volume_collection`, `nimble_check_ssl`, `nimble_token_ttl`, `nimble_debug`,
`nimble_auto_iscsi_discovery` (default **on**), `nimble_iscsi_discovery_ips`, `content` (default
`images`, `rootdir`, `none`). Legacy pre-v0.0.25 spellings (`address`, `vnprefix`, …; map:
`%NIMBLE_LEGACY_CONFIG_KEYS`) still parse and are **canonicalized in-memory by `check_config`**
(legacy key deleted, canonical wins if both present) — internal code reads ONLY canonical keys.
Any storage.cfg rewrite persists canonical keys, so **upgrade all cluster nodes before config
changes** (≤ v0.0.24 can't parse `nimble_*` keys).

**Property registration rules (violating these kills every PVE daemon at startup):** PVE SectionConfig
merges each plugin's `properties()` into ONE global namespace and **dies on any duplicate name**, even
with an identical schema — and `init()` merges plugins in **random hash order** per process. Never
declare in `properties()`: names the base class owns (`port`, `nodes`, `content`, `format`, `shared`,
`options`, …) or names core plugins own (`username`, `password`). Canonical `nimble_*` names can't
collide by construction. Legacy names are declared **only when unclaimed**: `properties()` scans the
registered-plugin list (fully populated *before* init calls any properties(), hence deterministic for
both merge orders — a propertyList-only check is racy) plus the propertyList, and drops claimed names;
`options()` references a legacy name only if it exists globally (else init dies "undefined property").
The Docker verify script runs a real register + init + createSchema load test **plus a co-install
simulation** (fake rival plugin owning address/vnprefix/check_ssl/token_ttl/debug, 10 random-order
inits) and a legacy/canonical storage.cfg parse test (a plain `perl -c` cannot catch any of this —
init runs before a temp-path plugin is registered).

### Nimble API

- Base: `https://<address>:5392/v1/`, body/response `{ "data": ... }`, token via `POST tokens`.
- Volume on array: `nimble_volname(scfg, volname [, snap])` → optional prefix + `vm-100-disk-0` + `.snap-<name>`.
- **Restore** (rollback): `POST volumes/:id/actions/restore` with `base_snap_id` (volume must be offline — plugin disconnects first).
- **Clone:** `POST volumes` with `clone`, `base_snap_id`, then ACL (+ optional `volcoll_id`).

### Host path (iSCSI → disk)

1. ACL + per-volume IQN session (`nimble_volume_connection` / `nimble_iscsi_establish_volume_session`).
2. `map_volume`: rescan, wait for device by **API serial**, multipath.
3. `filesystem_path` / `path($storeid)`: block device path; if missing → `activate_volume` (for vmstate / early `path()`).

### Important subs (grep starting points)

| Area | Functions |
|------|-----------|
| API | `nimble_api_call`, `nimble_data_as_list` |
| iSCSI | `run_iscsi_discovery_and_login`, `nimble_iscsi_node_login_if_needed`, `nimble_iscsi_establish_volume_session` |
| Map | `map_volume`, `unmap_volume`, `get_device_path_by_serial` |
| Snapshots | `volume_snapshot`, `nimble_snapshot_create`, `nimble_volume_restore`, `nimble_sync_array_snapshots` |
| RAM path | `nimble_resolve_block_path_for_volname`, `filesystem_path` |
| Delete | `nimble_remove_volume`, `free_image` |

### Pure plugin differences

- Auth: Nimble session token (user/pass), not Pure API token property.
- ACL: initiator groups + `access_control_records`, not Pure “connections.”
- iSCSI: this plugin runs `iscsiadm` in `map_volume`; Pure uses array connections API.
- `sub api`: use `PVE::Storage::APIVER()` **with `()`** — not bareword (strict subs on Perl 5.36+).

### Taint

Under `perl -T`, IQNs/portals for `iscsiadm` must pass `nimble_untaint_iscsiadm_scalar` or login silently fails inside `eval`.

---

## Array snapshot sync (pointer)

`nimble_sync_array_snapshots` (from `status()`, ~30s throttle): imports array-only snaps into QEMU configs as `nimble<epoch>`, descriptions `volume: snapshot name`, skips PVE `.snap-*` duplicates. Sparse list rows → `nimble_hydrate_snapshot_detail`. **QEMU only** (not LXC). Full behavior: [API_VALIDATION.md](API_VALIDATION.md) and code in `nimble_sync_array_snapshots`.

---

## When changing API usage

Follow `.cursor/rules/api-compatibility.mdc`: validate against [NIMBLE_API_REFERENCE.md](NIMBLE_API_REFERENCE.md), update [API_VALIDATION.md](API_VALIDATION.md), use restore vs clone correctly.

---

## Releases

1. Next tag: `git tag -l 'v*' | sort -V` → use **next sequential** version only.
2. Add `.github/release-notes-<tag>.md` before tagging.
3. See `.cursor/rules/releases.mdc`.

---

## Run / build

| Task | Command |
|------|---------|
| Unit tests | `./tests/run_tests.sh` |
| Syntax in Docker | `./scripts/verify_plugin_in_docker.sh` |
| Build .deb | `./scripts/build_deb.sh` |
| Install cluster | `scripts/install-pve-nimble-plugin.sh` |
| Live API probe | `scripts/nimble_api_unknowns_probe.sh` |
| Snapshot sync debug | `scripts/nimble_snapshot_sync_diagnostic.sh` |
| Add storage | `pvesm add nimble <id> --nimble_address https://<host> --username … --password … --content images,rootdir` |

---

## Conventions

- Errors: `die "Error :: …"`; debug: `$DEBUG` levels, `NIMBLE_DEBUG` env.
- Type: `nimble`; in `@PVE::Storage::Plugin::SHARED_STORAGE`.
- Package: `libpve-storage-nimble-perl` → `/usr/share/perl5/PVE/Storage/Custom/NimbleStoragePlugin.pm`.

---

*Update this file when status, major behavior, or default workflows change.*
