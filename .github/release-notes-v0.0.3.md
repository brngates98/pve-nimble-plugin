# Release notes – v0.0.3

## Highlights

- **HPE Nimble API alignment** – Request/response handling now follows the official REST API (including the `data` wrapper). Login uses `{ "data": { "username", "password" } }` and reads `session_token` from `data` when present.
- **Volume restore** – Restore endpoint corrected to `POST v1/volumes/:id/actions/restore` with body `id` and `base_snap_id` (fixes rollback from snapshot).
- **Clone from snapshot** – Clone now uses **POST volumes** with `clone: true`, `name`, and `base_snap_id` instead of the restore API, so new volumes are created correctly from snapshots.
- **Snapshot create** – Parameter order fixed so the volume name and snapshot name are passed correctly to the API.
- **Pool usage** – Storage status handles both numeric `usage` and nested `{ compressed_usage`, `uncompressed_usage }` for compatibility across Nimble versions.
- **Documentation** – Added in-repo API reference (`docs/NIMBLE_API_REFERENCE.md`) and validation notes (`docs/API_VALIDATION.md`). AI/contributor rules require validating implementations against the API.

## Installation

- **APT (Bookworm):** Add the repo from GitHub Pages (see README) or install the `.deb` from the Assets below.
- **Manual:** Download `libpve-storage-nimble-perl_*.deb` from Assets and install with `dpkg -i`.

## Upgrading from v0.0.2

No config changes required. Existing storage and volumes continue to work. Clone and snapshot rollback behavior is corrected.
