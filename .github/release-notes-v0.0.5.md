# Release notes – v0.0.5

## Highlights

- **Volume collection (protection plans)** – New optional storage option `volume_collection`. Set it to the name of an existing Nimble volume collection; every **new** volume and every **clone** from snapshot will be added to that collection so array-side protection/snapshot schedules apply.
- **Clone + volume collection** – Clones created via “Clone” from snapshot now join the configured `volume_collection` when set, same as newly created disks.
- **Restore workflow** – New guide **docs/00-SETUP-FULLY-PROTECTED-STORAGE.md** includes a step-by-step **Restore a disk from the array** section: rollback from PVE VM snapshot, clone from array snapshot, and in-place restore via Nimble UI or REST API (with curl examples).
- **Documentation** – README: Protection plans (Nimble-side), Backup and snapshot target (VM snapshots vs vzdump vs array snapshots), and link to the restore workflow. API reference updated for volume_collections and volume update with `volcoll_id`. AI_PROJECT_CONTEXT and setup doc updated.
- **API response handling** – Safer handling when Nimble returns a single object instead of an array for GET volume_collections and GET volumes (by name).

## Configuration

To put new disks and clones under a Nimble protection schedule:

1. In Nimble, create a protection template and a volume collection (or use an existing one).
2. Set `volume_collection` on the storage (e.g. in `/etc/pve/storage.cfg` or when adding storage):

```text
nimble: <storage_id>
  address https://<nimble>
  username <user>
  password <pass>
  content images
  volume_collection pve-daily
```

New volumes and clones from snapshot will be added to that collection. Existing volumes are unchanged; add them in the Nimble UI or via API if needed.

## Installation

- **APT (Bookworm):** Add the repo from GitHub Pages (see README) or install the `.deb` from the Assets below.
- **Manual:** Download `libpve-storage-nimble-perl_*.deb` from Assets and install with `dpkg -i`.

## Upgrading from v0.0.4

No config changes required. To use volume collections, add `volume_collection <name>` to the storage config. The new setup/restore guide is in `docs/00-SETUP-FULLY-PROTECTED-STORAGE.md`.
