# Screenshots (Proxmox + Nimble UI)

These images document **lab workflows** for the Nimble storage plugin: storage visibility in PVE, **VM disks** (and **CT Volumes** / `rootdir` when enabled — not all screens are shown here), snapshots, optional live migration, and the Nimble array UI. The **storage Summary** screenshot is also on the repository **[README.md](../README.md)** (Overview). They are referenced from **[docs/00-SETUP-FULLY-PROTECTED-STORAGE.md](../00-SETUP-FULLY-PROTECTED-STORAGE.md)** and indexed in **[docs/README.md](../README.md)**.

| File | Topic |
|------|--------|
| [pve-storage-summary-nimble.png](pve-storage-summary-nimble.png) | **Datacenter → Storage → Summary** — Nimble-backed store: type `nimble`, usage bar, history graph. |
| [pve-storage-vm-disks-raw.png](pve-storage-vm-disks-raw.png) | **Storage → VM Disks** — `vm-<vmid>-disk-*` volumes (example: **raw**). |
| [pve-storage-vm-disks-qcow2.png](pve-storage-vm-disks-qcow2.png) | **Storage → VM Disks** — same view with **qcow2** images (format depends on how disks were created). |
| [pve-vm-snapshot-create-dialog.png](pve-vm-snapshot-create-dialog.png) | **VM → Snapshots → Take snapshot** — create dialog (name, optional RAM). |
| [pve-snapshot-task-viewer-success.png](pve-snapshot-task-viewer-success.png) | Task log: snapshot task completed (`TASK OK`), volume name on Nimble store. |
| [pve-vm-snapshots-nimble-tree.png](pve-vm-snapshots-nimble-tree.png) | Snapshot tree with **`nimble*`** entries and descriptions (`volume: snapshot name`) after array sync. |
| [pve-migrate-vm-dialog.png](pve-migrate-vm-dialog.png) | **Migrate** dialog — target node, online mode. |
| [pve-migration-task-viewer.png](pve-migration-task-viewer.png) | Task log: live migration completed successfully. |
| [nimble-ui-volumes-list.png](nimble-ui-volumes-list.png) | **Nimble UI — Volumes** list (per-volume usage, performance). |
| [nimble-ui-take-snapshot-modal.png](nimble-ui-take-snapshot-modal.png) | **Nimble UI** — manual **Take snapshot** on a volume (array-side; distinct from PVE VM snapshots). |
