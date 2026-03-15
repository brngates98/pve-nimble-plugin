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
| **Auth** | Implemented | Username/password → POST /v1/tokens → session token; cached under `/etc/pve/priv/nimble/<storeid>.json` |
| **ACL / initiator** | Implemented | User must create a Nimble **initiator group** (with host IQN); plugin adds **access_control_records** (vol_id + initiator_group_id) when creating volumes |
| **Snapshots** | Implemented | Create, delete, rollback; Nimble snapshots API + volume restore |
| **Clone from snapshot** | Implemented | Via volume restore to new volume name |
| **Multipath** | Implemented | Same pattern as Pure: device by serial, multipathd add/remove map, block device actions |
| **Device discovery** | Implemented | By SCSI serial from `/sys/block/*/device/serial` and `/dev/disk/by-id`; no Nimble-specific WWN prefix (unlike Pure’s fixed prefix) |
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
│   └── AI_PROJECT_CONTEXT.md  # This file (AI/context)
├── .github/workflows/         # checks, lint, tests, release, _deb
├── debian/                    # Package: libpve-storage-nimble-perl
├── scripts/
│   └── build_deb.sh           # Local Docker build
└── tests/
    ├── run_tests.sh
    ├── unit/*.t               # Perl unit tests
    └── token_cache_test.pl
```

---

## 4. How the Plugin Fits Together

- **Config (storage.cfg):** `address`, `username`, `password`, `initiator_group` (required), optional `vnprefix`, `pool_name`, `check_ssl`, `token_ttl`, `debug`.
- **Nimble API base:** `https://<address>:5392/v1/`. Auth: POST `tokens` with username/password → use `session_token` as `X-Auth-Token` on later requests.
- **Volume naming:** `nimble_volname(scfg, volname, [snapname])` = optional prefix + volname (e.g. `vm-100-disk-0`) + optional `.snap-<name>` for snapshots.
- **Key API calls:** volumes (GET/POST/PUT/DELETE), access_control_records (POST to grant vol to initiator group), snapshots (POST create, GET by name, DELETE), volume restore (POST with base_snap_id).
- **Device path:** Volume `serial_number` from API → find block device by serial under `/sys/block/*/device/serial` and `/dev/disk/by-id` → optional multipath by WWID.

---

## 5. Differences from Pure Storage Plugin (reference)

- **Auth:** Nimble = username/password → session_token; Pure = API token → login → x-auth-token.
- **ACL:** Nimble = initiator groups + access_control_records (vol_id, initiator_group_id); Pure = host/volume “connections.”
- **API shape:** Nimble = `/v1/` JSON with `data` arrays; Pure = custom filter/params and `items`.
- **Cache:** Nimble = one file per storage (`<storeid>.json`); Pure = per-array (`<storeid>_arrayN.json`) for Active Cluster.

---

## 6. What Might Need Work (when resuming)

- **Validate on real Nimble:** Create storage, create VM disk, snapshot, clone, resize, delete; confirm device paths and multipath on a real node.
- **Nimble API quirks:** Response shapes (e.g. list vs single object, pagination) may need adjustment per Nimble firmware; error codes/messages might need better handling.
- **Status/capacity:** `status()` uses pools API; field names (`capacity`, `usage`, etc.) may vary by Nimble version—verify and adjust if needed.
- **Changelog for first release:** Handled: `_deb.yml` has a no-tags fallback (builds 1.0.0-1 from full history when no tags exist). Pushing a tag (e.g. `v1.0.0`) runs the release workflow and produces the .deb.

---

## 7. How to Run Things (for AI or human)

- **Unit tests:** `./tests/run_tests.sh` or `perl -I. tests/unit/<file>.t`. Requires Perl, Test::More, JSON (and JSON::XS for token_cache_test.pl).
- **Lint:** perltidy with `.perltidyrc`; markdownlint with `.markdownlint.json`. CI runs these on changed files.
- **Build .deb:** `./scripts/build_deb.sh` (Docker, Debian bookworm) or CI on tag push.
- **Install (manual):** Copy `NimbleStoragePlugin.pm` to `/usr/share/perl5/PVE/Storage/Custom/` on a PVE node and restart pvedaemon/pveproxy. Or install the built .deb.
- **Add storage (example):**  
  `pvesm add nimble <id> --address https://<nimble> --username <u> --password <p> --initiator_group <name> --content images`

---

## 8. Conventions to Keep

- Follow the same structure and style as **pve-purestorage-plugin** (Perl style, error messages "Error :: ...", debug with `$DEBUG`, token cache under `/etc/pve/priv/`).
- Storage type is `nimble`; shared storage is declared with `push @PVE::Storage::Plugin::SHARED_STORAGE, 'nimble'`.
- Debian package name: `libpve-storage-nimble-perl`; plugin file goes to `PVE/Storage/Custom/NimbleStoragePlugin.pm`.

---

*Last updated: repo URL and first-release prep. Update this file when you make significant changes or when status/next steps change.*
