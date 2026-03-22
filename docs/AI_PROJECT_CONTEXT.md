# AI Project Context: PVE Nimble Storage Plugin

**Purpose of this document:** Give an AI (or human) enough context to continue this project without prior conversation. Read this first when resuming work.

---

## 1. What This Project Is

- **Name:** Proxmox VE plugin for **HPE Nimble Storage** over **iSCSI**.
- **Role:** Custom PVE storage backend. Lets Proxmox create, delete, resize, snapshot, and present Nimble volumes as VM disks (raw, iSCSI, optional multipath).
- **Language:** Perl. Single main module: `NimbleStoragePlugin.pm`, implementing the PVE storage plugin API.
- **Origin:** Cloned structure and patterns from **pve-purestorage-plugin** (Pure Storage array plugin). Same overall flow: REST API to array, token auth, volume CRUD, initiator/ACL mapping, multipath, Proxmox storage interface.

---

## 2. Current Status (as of project creation)

| Area | Status | Notes |
|------|--------|--------|
| **Core plugin** | Implemented | Create/delete/resize/rename volumes, list, status, activate/deactivate, map/unmap |
| **list_images / detach** | Fixed | `list_images` now honors PVE’s `vollist` and `vmid` like RBD: explicit volids (e.g. `unusedN:` in qemu config) are listed for reattach; without `vollist`, results filter by `vmid`. Previously ignoring `vollist` made detached disks “vanish” in the GUI. |
| **ACL on activate (initiator_group set)** | Fixed | `nimble_ensure_volume_acl_for_current_node` used to return immediately when `initiator_group` was set, so **no** access_control_record was created; LUN never presented → timeout waiting for disk. Now ACL is ensured for the configured group as well as for auto `pve-<nodename>`. |
| **Auth** | Implemented | Username/password → POST /v1/tokens → session token; cached under `/etc/pve/priv/nimble/<storeid>.json` |
| **ACL / initiator** | Implemented | **initiator_group** optional: if set, that group by name; if unset, **reuse** first iSCSI group containing this host’s IQN (API order, skip any group with CHAP/`chapuser_id` on initiators), else create `pve-<nodename>`. **access_control_records** on create/activate. |
| **Snapshots** | Implemented | Create, delete, rollback; Nimble snapshots API + volume restore; Veeam snapshot name normalization (`veeam_` → `veeam-`) |
| **Clone from snapshot** | Implemented | Via POST volumes with clone=true, name, base_snap_id (then ACL + optional volume_collection) |
| **Multipath** | Implemented | Same pattern as Pure: device by serial, multipathd add/remove map, block device actions |
| **Device discovery** | Implemented | **Pure-style first:** `/dev/disk/by-id/wwn-0x<api_serial>`, then any `by-id` name containing the API `serial_number` (needed for **multipath dm** — often no sysfs `device/serial`), then sysfs serial match. |
| **Auto iSCSI discovery** | Implemented | Opt-in `auto_iscsi_discovery` on **activate_storage**. **`map_volume`** mirrors manual PVE iSCSI (portal + per-volume IQN + LUN 0): portal list = **`iscsiadm` session IPs first**, subnets (**GET subnets/:id**), **network_interfaces/:id**, `iscsi_discovery_ips`; sendtargets + per-target login; **`node.startup=automatic`** per target+portal; **`iscsiadm -m session --rescan`**; **90s** wait + periodic SCSI rescan; device by **serial**; `multipath -v2`. |
| **Volume import/export** | Implemented | `raw+size` for backup/restore (e.g. Veeam V13+); size rounded up to full MB for odd-sector compatibility |
| **Debian package** | Present | `libpve-storage-nimble-perl`, debian/*, scripts/build_deb.sh |
| **CI (GitHub Actions)** | Present | checks, lint (Perl + Markdown), tests, release (tag → build .deb → gh-release) |
| **Unit tests** | Present | test_command_validation.t, test_retry_logic.t, test_token_cache.t (+ token_cache_test.pl); no live Nimble tests |
| **Real-array testing** | Not done | No automated tests against a real Nimble array; manual only |
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
│   ├── README.md              # Short pointer to main README
│   ├── 00-SETUP-FULLY-PROTECTED-STORAGE.md  # Step-by-step setup guide (zero to protected storage)
│   ├── AI_PROJECT_CONTEXT.md  # This file (AI/context)
│   ├── API_VALIDATION.md      # Nimble REST API call validation vs HPE docs
│   ├── NIMBLE_API_REFERENCE.md # In-repo extract of HPE REST API 5.1.1.0 (read for endpoint/request/response details)
│   └── STORAGE_FEATURES_COMPARISON.md # Feature and content-type comparison vs NFS, LVM, iSCSI, Ceph RBD
├── .github/workflows/         # release, _deb
├── debian/                    # Package: libpve-storage-nimble-perl
├── scripts/
│   ├── build_deb.sh            # Local Docker build
│   └── install-pve-nimble-plugin.sh  # Scripted install (single/cluster, APT or .deb)
└── tests/
    ├── run_tests.sh
    ├── unit/*.t               # Perl unit tests
    └── token_cache_test.pl
```

---

## 4. How the Plugin Fits Together

- **Config (storage.cfg):** `address`, `username` (legacy `nimble_user` is merged into `username` in `check_config`), optional `initiator_group` (if unset, plugin auto-creates/uses `pve-<nodename>` with local IQN), optional `vnprefix`, `pool_name`, optional **`volume_collection`**, `check_ssl`, `token_ttl`, `debug`, optional **`auto_iscsi_discovery`**. **Stock PVE has no Datacenter GUI to add/edit custom storage plugins**—operators use **`pvesm`**, cluster storage API, or hand-edited config. **`password` is the only sensitive key** in **`plugindata → sensitive-properties`** (do not add ad-hoc keys without also defining them in **`properties()`**, or **`pvedaemon`/`pveproxy` fail** with `undefined property` from SectionConfig). Hooks write **`/etc/pve/priv/storage/<storeid>.pw`** (same canonical path as ESXi/CIFS in pve-storage), plus **`.nimble.pw`** and **`/etc/pve/priv/nimble/<storeid>.pw`** for legacy clusters. Reads try **`.pw` first**. Plaintext `password` in `storage.cfg` only if set by hand. **`nimble_api_credentials`** falls back to **`storage` / `storagename` / `storeid` / `name` / `id`** in `$scfg` when resolving `.pw` paths on workers.
- **Nimble API base:** `https://<address>:5392/v1/`. Auth: POST `tokens` with username/password → use `session_token` as `X-Auth-Token` on later requests. List responses may use `data: { items: [ ... ] }`; `nimble_data_as_list` unwraps `items`. Discovery portals: **`iscsiadm` session IPs merged first**, GET `subnets` + `subnets/:id`, GET `network_interfaces` + **`network_interfaces/:id`**, optional **`iscsi_discovery_ips`**. Pure plugin differs: API **connections** + no `iscsiadm` in `map_volume` ([pve-purestorage-plugin](https://github.com/kolesa-team/pve-purestorage-plugin)).
- **Volume naming:** `nimble_volname(scfg, volname, [snapname])` = optional prefix + volname (e.g. `vm-100-disk-0`) + optional `.snap-<name>` for snapshots.
- **Key API calls:** volumes (GET/POST/PUT/DELETE), access_control_records (POST/DELETE), snapshots (POST create, GET by name or full list, DELETE), volume restore (POST with base_snap_id), **subnets** / **subnets/:id**, **network_interfaces** / **network_interfaces/:id** (discovery IP fallbacks). **Pure-aligned lifecycle:** `nimble_volume_connection($mode)` mirrors `purestorage_volume_connection` (connect before map, disconnect after unmap). **`nimble_remove_volume`** = Pure’s `purestorage_remove_volume` order (local DM cleanup → revoke all ACLs for volume → Nimble offline/snapshots → DELETE). **`nimble_resolve_initiator_group_id_no_create`** supports disconnect without creating groups. **`filesystem_path`** optional 4th arg `$storeid` + **`nimble_effective_storeid`** for API login; **`on_update_hook_full`** no-op like Pure.
- **Worker password:** Redacted `$scfg` on some nodes is handled via **`nimble_effective_storeid`** and extra **`$scfg`** keys; password files are read from **`priv/storage/<storeid>.pw`** (canonical), then **`.nimble.pw`**, then **`priv/nimble/<storeid>.pw`**.
- **Device path:** Volume `serial_number` from API → find block device by serial under `/sys/block/*/device/serial` and `/dev/disk/by-id` → optional multipath by WWID.

---

## 5. Differences from Pure Storage Plugin (reference)

- **Auth:** Nimble = username/password → session_token; Pure = API token → login → x-auth-token (`token` property — avoids clashing with globally registered `password`).
- **PVE property registry:** Do **not** declare `username` / `password` in Nimble’s **`properties()`** — RBD/CIFS already register them globally. List **`username` + `password` in `options()`**. **`plugindata → sensitive-properties`**: **`password` only**. Hooks run when storage is added/updated via **`pvesm` or API** (not a built-in custom-plugin GUI). **`pvesm`** uses underscores (`--auto_iscsi_discovery`), not hyphens, for multi-word options.
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

- **Validate on real Nimble:** Create storage, create VM disk, snapshot, clone, resize, delete; confirm device paths and multipath on a real node.
- **Nimble API quirks:** Response shapes (e.g. list vs single object, pagination) may need adjustment per Nimble firmware; error codes/messages might need better handling.
- **Status/capacity:** `status()` uses pools API; field names (`capacity`, `usage`, etc.) may vary by Nimble version—verify and adjust if needed.
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
- **Lint:** perltidy with `.perltidyrc`; markdownlint with `.markdownlint.json`. CI runs these on changed files.
- **Build .deb:** `./scripts/build_deb.sh` (Docker, Debian bookworm) or CI on tag push.
- **Install (manual):** Copy `NimbleStoragePlugin.pm` to `/usr/share/perl5/PVE/Storage/Custom/` on a PVE node and restart pvedaemon/pveproxy. Or install the built .deb.
- **Scripted install:** `scripts/install-pve-nimble-plugin.sh` — single-node or cluster-wide (all nodes via SSH), from APT repo or a specific GitHub release .deb; supports `--dry-run`, `--yes`, `--all-nodes` (same pattern as Blockbridge’s get script).
- **Add storage (example):**  
  `pvesm add nimble <id> --address https://<nimble> --username <u> --password <p> --initiator_group <name> --content images`

---

## 8. Conventions to Keep

- Follow the same structure and style as **pve-purestorage-plugin** (Perl style, error messages "Error :: ...", debug with `$DEBUG`, token cache under `/etc/pve/priv/`).
- Storage type is `nimble`; shared storage is declared with `push @PVE::Storage::Plugin::SHARED_STORAGE, 'nimble'`.
- Debian package name: `libpve-storage-nimble-perl`; plugin file goes to `PVE/Storage/Custom/NimbleStoragePlugin.pm`.

---

*Last updated: repo URL and first-release prep. Update this file when you make significant changes or when status/next steps change.*
