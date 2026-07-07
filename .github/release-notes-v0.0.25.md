# Release notes – v0.0.25

**Proxmox VE Plugin for HPE Nimble Storage (iSCSI)**

This plugin adds HPE Nimble Storage as a custom storage backend in Proxmox VE. It uses the Nimble REST API to create and manage volumes and presents them as VM disks (and LXC root volumes) over iSCSI, with optional multipath.

---

## What is new in v0.0.25

### Unique `nimble_*` config option names — co-installation with other storage plugins is now safe

Proxmox merges every storage plugin's config properties into **one global namespace** and refuses to start its daemons if two plugins declare the same name — even with identical definitions. This plugin was derived from pve-purestorage-plugin and inherited its generic property names (`address`, `vnprefix`, `check_ssl`, `token_ttl`, `debug`), so installing both plugins on one node could kill all PVE daemons at startup. The v0.0.24 guard only protected one of the two possible load orders — and Proxmox initializes plugins in **random order per process**, so a co-installed node still failed to start on roughly half of all daemon starts.

v0.0.25 fixes this for both load orders:

- **All plugin config options are renamed** to unique, `nimble_`-prefixed names that cannot collide with the Proxmox base classes, core plugins, or any other custom plugin:

  | Old name (≤ v0.0.24) | New name (v0.0.25+) |
  |----------------------|---------------------|
  | `address` | `nimble_address` |
  | `vnprefix` | `nimble_vnprefix` |
  | `check_ssl` | `nimble_check_ssl` |
  | `token_ttl` | `nimble_token_ttl` |
  | `debug` | `nimble_debug` |
  | `initiator_group` | `nimble_initiator_group` |
  | `pool_name` | `nimble_pool_name` |
  | `volume_collection` | `nimble_volume_collection` |
  | `auto_iscsi_discovery` | `nimble_auto_iscsi_discovery` |
  | `iscsi_discovery_ips` | `nimble_iscsi_discovery_ips` |
  | `storeid` (auto-set) | `nimble_storeid` (auto-set) |

  (`username`, `password`, `port`, `nodes`, `content`, `format`, `disable` are Proxmox-owned names and are unchanged.)

- **The old spellings keep working** — existing `storage.cfg` entries need **no edits**. The plugin declares a legacy name only when no other installed plugin claims it, using a deterministic check against the registered-plugin list (safe in both load orders, unlike the v0.0.24 propertyList check), and rewrites legacy keys to the new names in-memory when the config is parsed.
- The verify pipeline now includes a **co-install load test**: a fake rival plugin declaring the shared generic names is installed alongside this plugin and the full Proxmox storage stack is initialized 10 times (fresh process each time, exercising both random merge orders), plus a legacy/canonical `storage.cfg` parse test.

### Corrected co-installation guidance

v0.0.24's notes said co-installation stays unsafe "until the Pure plugin adopts the guard". That was the wrong fix direction: this plugin is the newer one and should never have redeclared names Pure already owned. With v0.0.25's unique names, **the Pure plugin needs no changes** and both plugins can be installed together. README and docs have been rewritten accordingly.

---

## Upgrading

- **Existing configs keep working unchanged.** The plugin reads the old option spellings and treats them as the new names.
- **Clusters: upgrade the plugin package on ALL nodes before making any storage config change.** The next time Proxmox rewrites `storage.cfg` (any `pvesm add`/`set`/`remove`, for *any* storage), nimble sections are re-written with the new `nimble_*` names — and nodes still running ≤ v0.0.24 cannot parse those keys and would lose the storage definition until upgraded.
- Update your own scripts/automation to the new flags (e.g. `pvesm set <id> --nimble_debug 1` instead of `--debug 1`). Old flags keep working on nimble-only installs, but the new names are load-order-proof and future-proof.
- **From v0.0.23:** upgrade immediately (see v0.0.24 notes — v0.0.23 breaks PVE daemon startup).
- On a cluster, install on **every node** (`apt upgrade` from the GitHub Pages repo, or the `.deb` from Assets). postinst restarts `pvedaemon`, `pvestatd`, `pveproxy`, `pvescheduler`.

---

## Requirements

- **Proxmox VE** 8.2+ (Debian bookworm) or 9.x (Debian trixie)
- **HPE Nimble** array with REST API enabled (default port 5392)
- **iSCSI** initiator on each node (`open-iscsi`) with IQN in `/etc/iscsi/initiatorname.iscsi`
- (Optional) `nimble_initiator_group`; otherwise the plugin creates `pve-<nodename>` per node

---

## Configuration

```bash
pvesm add nimble <storage_id> --nimble_address https://<nimble> \
  --username <user> --password '<password>' --content images,rootdir
```

See the [README](https://github.com/brngates98/pve-nimble-plugin#configuration) for all options and the option-name migration table.

---

## Installation

- **APT – PVE 8 (bookworm):** `deb [...] https://brngates98.github.io/pve-nimble-plugin bookworm main`
- **APT – PVE 9 (trixie):** `deb [...] https://brngates98.github.io/pve-nimble-plugin trixie main`
- **Scripted install:** [README – scripted install](https://github.com/brngates98/pve-nimble-plugin#installation)
- **Manual:** Download `libpve-storage-nimble-perl_0.0.25-1_all.deb` from Assets and run `apt install ./…deb` or `dpkg -i`.

**Important:** On a cluster, install the plugin on every node.

---

## Documentation

| Document | Description |
|----------|-------------|
| [README](https://github.com/brngates98/pve-nimble-plugin#readme) | Install, config, option-name migration, troubleshooting |
| [docs/API_VALIDATION.md](https://github.com/brngates98/pve-nimble-plugin/blob/main/docs/API_VALIDATION.md) | Plugin ↔ Nimble REST validation |
| [docs/NIMBLE_API_REFERENCE.md](https://github.com/brngates98/pve-nimble-plugin/blob/main/docs/NIMBLE_API_REFERENCE.md) | In-repo HPE REST API extract |
| [docs/AI_PROJECT_CONTEXT.md](https://github.com/brngates98/pve-nimble-plugin/blob/main/docs/AI_PROJECT_CONTEXT.md) | Maintainer / AI context |

---

## Package

- **Name:** `libpve-storage-nimble-perl`
- **Version:** 0.0.25-1
- **Install path:** `NimbleStoragePlugin.pm` → `/usr/share/perl5/PVE/Storage/Custom/`
- **Maintainer scripts:** postinst try-restarts `pvedaemon`, `pvestatd`, `pveproxy`, `pvescheduler`; postrm does the same on remove/purge.

---

## Contributors and quality

- **CI:** Unit tests (including new legacy-key canonicalization and deterministic-guard regression tests), plugin syntax, the full PVE::Storage register + init + createSchema load test, a legacy/canonical `storage.cfg` parse test, and a 10-iteration co-install load test (bookworm + trixie) must pass before the release deb build.
