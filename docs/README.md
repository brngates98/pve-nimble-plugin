# Documentation index

The repository root **[README.md](../README.md)** is the main entry: install, configure Proxmox storage, multipath, and troubleshooting.

Use this page to choose **guides** vs **API / development** material without hunting filenames.

---

## Operators (install & run)

| Doc | What it is |
|-----|------------|
| **[README.md](../README.md)** | Requirements, scripted install, `pvesm` options, multipath, troubleshooting, debug, informal real-array validation note. |
| **[00-SETUP-FULLY-PROTECTED-STORAGE.md](00-SETUP-FULLY-PROTECTED-STORAGE.md)** | Long-form walkthrough: from empty cluster to Nimble-backed VMs, array snapshots, optional multipath. (The `00-` prefix only sorts this guide first in directory listings.) |
| **[STORAGE_FEATURES_COMPARISON.md](STORAGE_FEATURES_COMPARISON.md)** | How this Nimble plugin compares to NFS, LVM, plain iSCSI, Ceph RBD for features and workflows. |

---

## API & validation (REST contract)

| Doc | What it is |
|-----|------------|
| **[NIMBLE_API_REFERENCE.md](NIMBLE_API_REFERENCE.md)** | In-repo extract of the HPE Nimble REST API (paths, `data` envelope, volumes/snapshots/restore/delete, iSCSI-related notes). |
| **[API_VALIDATION.md](API_VALIDATION.md)** | How `NimbleStoragePlugin.pm` maps to that API: endpoints used, restore vs clone, snapshot rollback (offline/online on the array), delete paths, token retry. |

Official HPE docs are linked from those files when you need the full reference.

---

## Development & contributions

| Doc | What it is |
|-----|------------|
| **[CONTRIBUTING.md](../CONTRIBUTING.md)** | How to contribute, tests, packaging. |
| **[AI_PROJECT_CONTEXT.md](AI_PROJECT_CONTEXT.md)** | Maintainer/AI-oriented: repo layout, what is implemented, gaps, how to run tests and build the `.deb`. Read this when continuing plugin work in a new session. |
| **[tests/README.md](../tests/README.md)** | Unit test layout and how to run them. |

---

## Quick map (if you know what you need)

- **Install the plugin today** → [README.md](../README.md)
- **Step-by-step protected storage tutorial** → [00-SETUP-FULLY-PROTECTED-STORAGE.md](00-SETUP-FULLY-PROTECTED-STORAGE.md)
- **Why restore needs array offline / how delete uses `online`** → [API_VALIDATION.md](API_VALIDATION.md) (snapshot rollback section)
- **Raw API tables** → [NIMBLE_API_REFERENCE.md](NIMBLE_API_REFERENCE.md)
- **Change the plugin / run tests** → [AI_PROJECT_CONTEXT.md](AI_PROJECT_CONTEXT.md)

Release notes for each git tag live under **[.github/release-notes-*.md](../.github/)** (see also the releases rule in `.cursor/rules/releases.mdc` if you cut releases).
