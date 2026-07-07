# Release notes – v0.0.24

> **Erratum (superseded by v0.0.25):** this release's guidance that co-installation with
> pve-purestorage-plugin stays unsafe "until the Pure plugin adopts the guard" was the wrong fix
> direction. v0.0.25 renames this plugin's config options to unique `nimble_*` names, making
> co-installation safe in both load orders with **no changes needed in the Pure plugin**. See the
> v0.0.25 release notes.

**Proxmox VE Plugin for HPE Nimble Storage (iSCSI)**

This plugin adds HPE Nimble Storage as a custom storage backend in Proxmox VE. It uses the Nimble REST API to create and manage volumes and presents them as VM disks (and LXC root volumes) over iSCSI, with optional multipath.

---

## ⚠️ CRITICAL: v0.0.23 breaks PVE daemon startup — upgrade immediately

**v0.0.23 must not be installed.** It declared a `port` config property that collides with a property the Proxmox storage framework itself registers globally; Proxmox's `PVE::SectionConfig` refuses duplicate property names and the failure happens outside any error handling, so with v0.0.23 installed **`pvedaemon`, `pvestatd`, `pveproxy`, and `pvescheduler` all fail to start** (`duplicate property 'port'`). Running VMs are unaffected (QEMU and cluster/corosync keep running), but the node loses its GUI, API, and monitoring until the package is upgraded or removed.

**If a node already installed v0.0.23:** SSH in and run `apt update && apt install libpve-storage-nimble-perl` (this release supersedes it in the APT repo), or `apt remove libpve-storage-nimble-perl`, then start the four services (`systemctl start pvedaemon pvestatd pveproxy pvescheduler`).

The plugin verify pipeline now performs a real register + init + schema load test against the installed Proxmox storage stack (a plain syntax check cannot catch this class of bug), so this cannot recur silently.

---

## What is new in v0.0.24

Everything below came out of a full independent safety/correctness audit against the Proxmox storage plugin contract (pve-storage source + ApiChangeLog), the HPE Nimble REST API (SDK reference), and the Pure Storage plugin.

### Critical / high

- **Fixed: v0.0.23 `port` property collision** (see banner above). `port` is now referenced via the framework's own global property, the way PBS/ESXi do — it remains configurable (`--port`).
- **Property-collision guard for co-installation** — `properties()` now skips any name another plugin has already registered. This plugin and pve-purestorage-plugin both declared `address`, `vnprefix`, `check_ssl`, `token_ttl`, `debug`; two plugins declaring the same name kills PVE daemon startup just like the `port` bug. The guard makes this plugin safe when it loads second; the Pure plugin still needs the equivalent fix for co-installation to be fully safe (see README Requirements note — until then, don't install both on one node).
- **iSCSI auto-discovery can no longer touch foreign arrays** — portal IPs harvested from existing host sessions (which can belong to Pure or any other vendor's array) are now used only as a last-resort fallback when the Nimble subnets API and manual config yield nothing, **and** baseline login filters targets to Nimble vendor IQNs. Previously, a foreign portal in the discovery list would get *all its targets* logged in and set to automatic startup.
- **Live migration with a shared initiator group no longer loses disk access** — with `initiator_group` set in storage.cfg (or an auto-selected group listing several hosts' IQNs), all nodes share ONE access-control record per volume. Volume deactivation on the migration source used to delete it — revoking the array ACL out from under the VM already running on the target. Deactivation now only revokes the per-node auto group (`pve-<nodename>`); shared-group ACLs persist until volume deletion.

### Medium

- **Array-snapshot sync no longer clobbers other storages' imports** — a VM with disks on two Nimble storages had each storage's sync deleting the other's imported `nimble*` snapshot entries every 30s (add/delete flip-flop). Stale-entry removal is now scoped to entries whose description references this storage's own volumes, and is skipped entirely when the snapshot fetch was partial (transient API failures no longer delete valid entries).
- **pvestatd protection** — the snapshot sync and iSCSI baseline refresh that run from `status()` now have hard wall-clock budgets (25s / 30s), and a failed refresh attempt is throttled the same as a successful one. A slow or half-reachable array can no longer stall monitoring for every storage on the node.
- **Faster VM starts** — `activate_storage` no longer runs a full discovery round-trip on every call; it shares the 60s throttle with the status refresh (first call after boot always runs; per-volume session setup still happens on volume activation).
- **Password no longer stored in storage.cfg** — `password` is now a PVE *sensitive property*: it lives in `/etc/pve/priv/storage/<storeid>.pw` (root-only) instead of the cluster-replicated, GUI-visible `storage.cfg`. Existing configs with a cfg password keep working; the first `pvesm set <id> --password ...` moves it to the priv file. Change passwords via `pvesm`/GUI, not by editing files.
- **Snapshot blockdev requests now fail loudly** — if PVE ever requests a QEMU blockdev for a *snapshot* of a Nimble volume, the plugin dies instead of silently attaching the live volume under the snapshot's name.

### Smaller fixes

- `parse_volname` follows the core-plugin contract: vtype `images` with the `isBase` flag (never the invalid `base` vtype), full volume name.
- PVE snapshots named `snap-*` no longer collide with their unprefixed counterparts on the array (`x` vs `snap-x` mapped to the same array snapshot; deleting one deleted the other's data).
- IPv6 array addresses are no longer mangled (`fd00::5392` used to lose its last hextet to port-stripping); bracketed and unbracketed IPv6 literals both work.
- Deleting a storage now also removes its multipath alias file and WWID cache (aliases no longer persist forever after storage removal).
- `rename_volume` migrates the multipath WWID-cache/alias entry to the new name and logs out the old per-volume IQN (Nimble target names embed the volume name, so the IQN changes on rename).
- ACR lookups on disconnect/delete now use the `?vol_id=` filter (with fallback) instead of fetching every access-control record on the array.
- Docs: `volume_resize` `$snapname` and `volume_snapshot_info` `virtual-size` are **APIVER 15** features per the official ApiChangeLog (earlier notes said 14 — code was always correct, additive on 14 hosts).
- New regression tests: property-collision guard, IQN scoping, IPv6 URL handling, `parse_volname` contract, snapshot-name collision (43 new assertions), plus the Docker register+init+createSchema load test.

---

## Upgrading

- **From v0.0.23:** upgrade immediately — see the banner at the top.
- **From v0.0.22 or earlier:** no config changes required. Note the password storage change above (transparent; applies on your next password update) and the new 60s discovery throttle on storage activation.
- On a cluster, install on **every node** (`apt upgrade` from the GitHub Pages repo, or the `.deb` from Assets). postinst restarts `pvedaemon`, `pvestatd`, `pveproxy`, `pvescheduler`.

---

## Requirements

- **Proxmox VE** 8.2+ (Debian bookworm) or 9.x (Debian trixie)
- **HPE Nimble** array with REST API enabled (default port 5392)
- **iSCSI** initiator on each node (`open-iscsi`) with IQN in `/etc/iscsi/initiatorname.iscsi`
- (Optional) `initiator_group`; otherwise the plugin creates `pve-<nodename>` per node
- **Do not co-install with pve-purestorage-plugin** until it adopts the property-collision guard (README Requirements note)

---

## Configuration

```bash
pvesm add nimble <storage_id> --address https://<nimble> \
  --username <user> --password '<password>' --content images,rootdir
```

See the [README](https://github.com/brngates98/pve-nimble-plugin#configuration) for all options.

---

## Installation

- **APT – PVE 8 (bookworm):** `deb [...] https://brngates98.github.io/pve-nimble-plugin bookworm main`
- **APT – PVE 9 (trixie):** `deb [...] https://brngates98.github.io/pve-nimble-plugin trixie main`
- **Scripted install:** [README – Option C](https://github.com/brngates98/pve-nimble-plugin#option-c-scripted-installer-single-node-or-all-cluster-nodes)
- **Manual:** Download `libpve-storage-nimble-perl_0.0.24-1_all.deb` from Assets and run `apt install ./…deb` or `dpkg -i`.

**Important:** On a cluster, install the plugin on every node.

---

## Documentation

| Document | Description |
|----------|-------------|
| [README](https://github.com/brngates98/pve-nimble-plugin#readme) | Install, config, troubleshooting |
| [docs/API_VALIDATION.md](https://github.com/brngates98/pve-nimble-plugin/blob/main/docs/API_VALIDATION.md) | Plugin ↔ Nimble REST validation |
| [docs/NIMBLE_API_REFERENCE.md](https://github.com/brngates98/pve-nimble-plugin/blob/main/docs/NIMBLE_API_REFERENCE.md) | In-repo HPE REST API extract |
| [docs/AI_PROJECT_CONTEXT.md](https://github.com/brngates98/pve-nimble-plugin/blob/main/docs/AI_PROJECT_CONTEXT.md) | Maintainer / AI context |

---

## Package

- **Name:** `libpve-storage-nimble-perl`
- **Version:** 0.0.24-1
- **Install path:** `NimbleStoragePlugin.pm` → `/usr/share/perl5/PVE/Storage/Custom/`
- **Maintainer scripts:** postinst try-restarts `pvedaemon`, `pvestatd`, `pveproxy`, `pvescheduler`; postrm does the same on remove/purge.

---

## Contributors and quality

- **CI:** Unit tests, plugin syntax, and a full PVE::Storage register + init + createSchema load test (bookworm + trixie) must pass before the release deb build.
