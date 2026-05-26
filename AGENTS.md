# AGENTS.md

## Cursor Cloud specific instructions

This is a **Perl-based Proxmox VE storage plugin** (single-file: `NimbleStoragePlugin.pm`). There is no running "application" to start — the plugin runs inside PVE daemons on a real Proxmox node. Development work focuses on editing the plugin, running unit tests, linting, syntax-checking, and building the `.deb` package.

### Quick reference

| Task | Command | Notes |
|------|---------|-------|
| **Unit tests** | `./tests/run_tests.sh` | All offline; no live Nimble array needed |
| **Single test** | `perl -I. tests/unit/<file>.t` | Run from repo root |
| **Perl lint** | `perltidy --pro=.perltidyrc -st NimbleStoragePlugin.pm` | Compare output with original; formatting is not strictly enforced in CI |
| **Markdown lint** | `markdownlint -c .markdownlint.json README.md CONTRIBUTING.md docs/*.md` | Some pre-existing warnings exist in docs |
| **Plugin syntax check** | `DIST=bookworm ./scripts/verify_plugin_in_docker.sh` | Requires Docker; also supports `DIST=trixie` for PVE 9 |
| **Build .deb** | `sudo bash scripts/build_deb.sh` | Requires Docker; output in `build/` — clean up with `sudo rm -rf build/ debian/.debhelper debian/debhelper-build-stamp debian/files debian/libpve-storage-nimble-perl.substvars debian/libpve-storage-nimble-perl` |

### Gotchas

- **Docker required for syntax check and .deb build.** The Docker daemon must be started with `sudo dockerd` before running `verify_plugin_in_docker.sh` or `build_deb.sh`. On Cloud Agent VMs, Docker needs `fuse-overlayfs` storage driver and `iptables-legacy` (see setup below).
- **Docker daemon startup:** Run `sudo dockerd &` in the background, or use a tmux session. The daemon needs a few seconds to start before `docker` commands work.
- **`build_deb.sh` creates root-owned files** under `debian/` and `build/`. Clean up with `sudo rm -rf` after building.
- **No PVE libraries on the host.** `perl -c NimbleStoragePlugin.pm` will fail outside Docker because `PVE::Storage::Plugin` and related modules are only available in Proxmox packages. Use `verify_plugin_in_docker.sh` instead.
- **`npm install -g` needs `NPM_CONFIG_PREFIX`** set to the nvm node path (e.g. `NPM_CONFIG_PREFIX=/home/ubuntu/.nvm/versions/node/v22.22.2`) for global installs to work without sudo.
- **Test warnings are normal.** `test_command_validation.t` emits warnings about missing `multipath`/`multipathd`/`blockdev`/`kpartx`/`dmsetup` — these are expected since the test creates dummy command paths and some are intentionally absent.

### Docker setup for Cloud Agent VMs (one-time)

If Docker is not already installed, the update script handles Perl deps only. Docker setup requires:

```bash
sudo apt-get update -qq
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin fuse-overlayfs iptables
sudo mkdir -p /etc/docker
printf '{\n  "storage-driver": "fuse-overlayfs"\n}\n' | sudo tee /etc/docker/daemon.json
sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
sudo dockerd &
```
