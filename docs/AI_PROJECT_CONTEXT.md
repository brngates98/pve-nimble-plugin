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
- Auto iSCSI discovery (default on): subnets API → sendtargets → **login only if IQN not in session** (no global `node --login`).
- `raw+size` import/export (e.g. Veeam V13+).
- Array snapshot **import** into QEMU VM configs (`nimble*` keys, throttled from `status()`).
- APIVER 12–14 (`storage` QEMU snapshots, `qemu_blockdev_options`, `get_identity`, etc.).
- Package + CI + unit tests (no live Nimble in CI).

### Partial / needs validation

- **RAM snapshots (vmstate):** `nimble_resolve_block_path_for_volname` activates/maps if `path()` runs before the LUN is visible — confirm on PVE 9.2+ with RAM enabled.
- **LXC `rootdir`:** implemented; exercise on your array if you rely on it.
- **`volume_collection`:** applied on **new** volumes/clones via storage config; normal snapshots OK in testing.

### Not tested / known gaps

- **Synchronous replication** on volume collections (especially **manual** membership in an existing sync-rep collection) — separate from PVE snapshots until field-tested; see README troubleshooting.
- Firmware-specific API shapes (`GET snapshots` without filter, list row sparsity) — see [API_VALIDATION.md](API_VALIDATION.md).
- Disconnect path fetches all ACRs (could filter by `vol_id`).

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

`address`, `username`, `password` (in cfg, cluster-replicated; mirrored to priv `.pw` on add/update), optional `initiator_group`, `vnprefix`, `pool_name`, `volume_collection`, `check_ssl`, `token_ttl`, `debug`, `auto_iscsi_discovery` (default **on**), `iscsi_discovery_ips`, `content` (default `images`, `rootdir`, `none`).

Do **not** add undeclared keys to `properties()` — PVE SectionConfig will reject them. Do **not** put `username`/`password` in `properties()` (global registry); use `options()` only.

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
| Add storage | `pvesm add nimble <id> --address https://<host> --username … --password … --content images,rootdir` |

---

## Conventions

- Errors: `die "Error :: …"`; debug: `$DEBUG` levels, `NIMBLE_DEBUG` env.
- Type: `nimble`; in `@PVE::Storage::Plugin::SHARED_STORAGE`.
- Package: `libpve-storage-nimble-perl` → `/usr/share/perl5/PVE/Storage/Custom/NimbleStoragePlugin.pm`.

---

*Update this file when status, major behavior, or default workflows change.*
