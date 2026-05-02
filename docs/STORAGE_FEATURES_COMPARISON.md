# Storage Features Comparison

This document compares the **HPE Nimble Storage plugin** (`nimble`) for Proxmox VE with other common storage types: NFS, LVM/LVM-thin, standard iSCSI, and Ceph RBD. The Nimble plugin supports **VM disks** and **LXC container storage** (`rootdir`) on raw volumes when `content` includes `rootdir`.

The **feature** and **content type** tables below are also copied in the root **[README.md](../README.md)** for visibility. Update **both** places when you change those tables (see [CONTRIBUTING.md](../CONTRIBUTING.md#documentation)).

---

## Feature comparison

| Feature | Nimble plugin | NFS | LVM / LVM-thin | iSCSI (kernel) | Ceph RBD |
|--------|----------------|-----|----------------|----------------|----------|
| **Snapshots** | ✅ | ⚠️ | ⚠️ | ⚠️ | ✅ |
| **VM state snapshots (vmstate)** | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Clones** | ✅ | ⚠️ | ⚠️ | ⚠️ | ✅ |
| **Thin provisioning** | ✅ | ⚠️ | ⚠️ | ⚠️ | ✅ |
| **Block-level performance** | ✅ | ❌ | ✅ | ✅ | ✅ |
| **Shared storage** | ✅ | ✅ | ⚠️ | ✅ | ✅ |
| **Automatic volume management** | ✅ | ❌ | ❌ | ❌ | ✅ |
| **Multi-path I/O** | ✅ | ❌ | ⚠️ | ⚠️ | ❌ |
| **Container storage (rootdir)** | ✅ | ✅ | ✅ | ❌ | ✅ |
| **Backup storage (vzdump)** | ❌ | ✅ | ❌ | ❌ | ❌ |
| **ISO storage** | ❌ | ✅ | ❌ | ❌ | ❌ |
| **Raw image format** | ✅ | ✅ | ✅ | ✅ | ✅ |

**Legend:** ✅ Native support | ⚠️ Via additional layer or conditions | ❌ Not supported

**Notes:**

- **Nimble plugin:** Native array integration (REST API). Volume create/delete/resize/rename (grow rescans iSCSI/multipath on the node after the array **`PUT`**, so UI resize aligns with **`blockdev`** size), ACL (initiator groups), snapshots, clone-from-snapshot, and array snapshot sync (array-created snapshots imported into PVE VM configs automatically). VM disks and LXC root (`rootdir`) on raw block; use NFS or directory for ISOs, backups, templates.
- **NFS:** Snapshots/clones via qcow2 or volume chains (file-based). Supports all content types. Block performance is file-layer, not raw block.
- **LVM / LVM-thin:** Snapshots/clones with LVM-thin, or snapshot-as-volume-chain on LVM (PVE 9+). Shared only when built on shared block (e.g. LVM on iSCSI LUN). No automatic volume management from PVE for SAN LUNs.
- **iSCSI (kernel):** Raw LUNs; thin/snapshots/clones depend on the target. No automatic volume management; you create LUNs and ACLs on the array. Multipath is configurable per target.
- **Ceph RBD:** Native thin, snapshots, clones. No backup/ISO content (use CephFS for file). Multipath not applicable (single logical connection).

---

## Content type compatibility matrix

| Content type | Nimble plugin | NFS | LVM / LVM-thin | iSCSI (kernel) | Ceph RBD |
|-------------|----------------|-----|----------------|----------------|----------|
| **VM disks** | ✅ | ✅ | ✅ | ✅ | ✅ |
| **CT volumes (rootdir)** | ✅ | ✅ | ✅ | ❌¹ | ✅ |
| **Backups (vzdump)** | ❌ | ✅ | ❌ | ❌ | ❌ |
| **ISO images** | ❌ | ✅ | ❌ | ❌ | ❌ |
| **CT templates (vztmpl)** | ❌ | ✅ | ❌ | ❌ | ❌ |
| **Snippets** | ❌ | ✅ | ❌ | ❌ | ❌ |

¹ *Plain* PVE iSCSI storage does not expose `rootdir`; use LVM (or similar) on top of the LUN, or a plugin like this one that manages volumes and presents block devices.

---

## By storage type

### Nimble plugin (`nimble`)

- **What it is:** PVE storage plugin for HPE Nimble arrays. Uses the Nimble REST API to create and manage volumes and presents them as iSCSI LUNs to Proxmox.
- **Content:** VM disks (`images`) and LXC root (`rootdir`) on raw volumes. No ISO, container templates, backup target, or snippets.
- **Thin provisioning:** Yes; Nimble provides thin provisioning at the array.
- **Snapshots:** Yes; storage-level snapshots via Nimble API (create, delete, rollback).
- **Clone:** Clone from snapshot (new volume from snapshot); no linked-clone base image.
- **Shared:** Yes; all nodes with the plugin and iSCSI access see the same volumes.
- **Live migration:** Yes; **QEMU** VM disks on shared block storage can be live-migrated. (LXC/CT migration follows normal PVE rules for `rootdir` on shared storage.)
- **Multipath:** Supported; plugin integrates with multipathd (device by SCSI serial).
- **Backup target:** No; vzdump expects file/directory storage. Use NFS, PBS, or directory storage for backups.

### NFS (`nfs`)

- **Level:** File. Full POSIX filesystem.
- **Content:** All types (images, iso, vztmpl, backup, snippets, rootdir).
- **Shared:** Yes. All nodes mount the same export.
- **Snapshots:** Via qcow2 or volume chains on file storage.
- **Use case:** Flexible shared storage; ISOs, templates, backups, VM disks. No array integration.

### LVM (`lvm`) / LVM-thin (`lvmthin`)

- **Level:** Block. Typically local to one node unless the PV is a shared LUN.
- **Content:** images, rootdir. No ISO/vztmpl/backup/snippets (no directory).
- **Thin / Snapshots / Clones:** LVM-thin provides thin provisioning, snapshots, and clones; plain LVM does not (PVE 9+ can use snapshot-as-volume-chain on LVM).
- **Shared:** Usually no (local VG). Can be shared if the VG is on a shared iSCSI/FC LUN.
- **Use case:** Local or “LVM on SAN” without array-specific API (manual LUN creation).

### iSCSI kernel (`iscsi`) / libiscsi (`iscsidirect`)

- **Level:** Block. Raw LUNs from any iSCSI target.
- **Content:** VM images only. No ISO, backup target, etc.
- **Shared:** Yes; all nodes can log in to the same target.
- **Thin / Snapshots / Clones:** Depends entirely on the array or target; PVE does not add them. No built-in snapshot/clone in PVE for plain iSCSI.
- **Use case:** Generic SAN; you manage LUNs and ACLs on the array. No automation from PVE.

### Ceph RBD (`rbd`)

- **Level:** Block. Distributed block via Ceph.
- **Content:** images, rootdir. No ISO/backup as file content (use CephFS for file).
- **Thin / Snapshots / Clones:** Yes; Ceph provides these.
- **Shared:** Yes; multi-node Ceph cluster.
- **Use case:** Software-defined shared block with full features; no hardware array.

### Directory (`dir`)

- **Level:** File. Local path or mounted filesystem (e.g. NFS mount).
- **Content:** All types (iso, vztmpl, backup, snippets, images if configured).
- **Shared:** Only if the path is on shared storage (e.g. NFS).
- **Use case:** Simple file storage; ISOs, backups, templates. Default `local` storage is directory type.

---

## When to use the Nimble plugin

- You have **HPE Nimble** arrays and want **tight integration**: volume create/delete/resize/rename, ACL (initiator groups), and snapshots/clone from snapshot from the Proxmox UI/API.
- You want **array-level thin provisioning and snapshots** without adding an extra layer (e.g. LVM thin on top).
- You want **multipath** and optional **auto iSCSI discovery** for Nimble.

Use **NFS** or **directory** storage (or PBS) for ISOs, container templates, and backup targets; the Nimble plugin is for **VM and LXC root** block volumes (`images`, `rootdir`), not file-based content types.

---

*Last updated to match plugin capabilities and Proxmox VE storage model. For plugin status and implementation details, see [AI_PROJECT_CONTEXT.md](AI_PROJECT_CONTEXT.md).*
