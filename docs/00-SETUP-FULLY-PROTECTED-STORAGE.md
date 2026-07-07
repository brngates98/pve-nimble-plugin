# Setup guide: Nimble storage on Proxmox VE

Step-by-step: install the plugin, add Nimble as storage, create disks, optional multipath, test snapshots.  
**Shorter reference:** [README.md](../README.md). **Feature comparison:** [STORAGE_FEATURES_COMPARISON.md](STORAGE_FEATURES_COMPARISON.md). **Screenshots:** [images/README.md](images/README.md).

---

## What you get

- One **Nimble volume per VM disk** (or LXC root if you enable `rootdir`) — no shared giant LUN + LVM on top.
- **Snapshots** from the Proxmox UI (array-backed); optional **multipath**; **cluster-wide** storage config (plugin on **every** node).

---

## Before you start

- [ ] Proxmox VE **8.2+** (9.x tested in the field).
- [ ] Nimble: REST API (port **5392**), at least one iSCSI subnet with a **discovery IP**.
- [ ] Network: management reachable from all nodes; iSCSI VLANs planned.
- [ ] API user that can create volumes, initiator groups, and ACLs.
- [ ] Plugin installed on **each** cluster node (config syncs; the `.pm` file does not).

---

## 1. Network

- **Management** — Proxmox reaches `https://<nimble>:5392`.
- **iSCSI** — Each node can reach Nimble **discovery IPs** (often one or two VLANs for multipath).

---

## 2. Nimble array

- Enable REST API and iSCSI subnets (type **data** or **mgmt,data** with `discovery_ip`).
- Confirm API login from a node:

```bash
curl -sk -X POST "https://<NIMBLE>:5392/v1/tokens" \
  -H "Content-Type: application/json" \
  -d '{"data":{"username":"<user>","password":"<password>"}}'
```

Expect `session_token` in the JSON response.

![Nimble volumes list](images/nimble-ui-volumes-list.png)

---

## 3. Install the plugin (every node)

```bash
# One node
curl -fsSL https://raw.githubusercontent.com/brngates98/pve-nimble-plugin/main/scripts/install-pve-nimble-plugin.sh | sudo bash

# Cluster (dry-run first)
curl -fsSL https://raw.githubusercontent.com/brngates98/pve-nimble-plugin/main/scripts/install-pve-nimble-plugin.sh | sudo bash -s -- --all-nodes --dry-run
curl -fsSL https://raw.githubusercontent.com/brngates98/pve-nimble-plugin/main/scripts/install-pve-nimble-plugin.sh | sudo bash -s -- --all-nodes
```

Or APT / `.deb` from [releases](https://github.com/brngates98/pve-nimble-plugin/releases). Verify: `dpkg -l libpve-storage-nimble-perl`.

---

## 4. open-iscsi (IQN)

Installer pulls in `open-iscsi`. Check:

```bash
sudo cat /etc/iscsi/initiatorname.iscsi   # must contain InitiatorName=iqn....
ls /sys/class/iscsi_host/                 # at least one host
```

---

## 5. Multipath (recommended)

```bash
sudo apt install multipath-tools
sudo systemctl enable --now multipathd
```

Use a **blacklist-all + Nimble exception** config (see [README multipath section](../README.md#multipath-optional)). The plugin maintains `/etc/multipath/conf.d/nimble-<storeid>.conf` — do not edit by hand.

```bash
sudo multipathd reconfigure
sudo multipath -ll
```

---

## 6. Add storage in Proxmox

From any node (config replicates):

```bash
pvesm add nimble <storage_id> \
  --nimble_address https://<NIMBLE_MGMT> \
  --username <API_USER> \
  --password '<API_PASSWORD>' \
  --content images,rootdir
```

- **`images` only** — omit LXC roots.
- **`--nimble_initiator_group <name>`** — use an existing Nimble group instead of auto `pve-<nodename>`.
- **iSCSI discovery** is **on** by default (`nimble_auto_iscsi_discovery`); set `0` only if you manage iSCSI yourself.
- Configs created before v0.0.25 use unprefixed option names (`address`, `initiator_group`, …); they keep working — see README **Upgrading from v0.0.24 or earlier**.

---

## 7. Verify

1. **Datacenter → Storage** — type **nimble**, usage/free shown.
2. Create a test **VM disk** on this store; start the VM.
3. Optional: **resize** disk in UI, extend partition inside guest.

![Storage summary](images/pve-storage-summary-nimble.png)  
![VM disks on store](images/pve-storage-vm-disks-raw.png)

---

## 8. Snapshots (QEMU VM)

1. **VM → Snapshots → Take snapshot** — name the snapshot.
2. Prefer **without RAM** if you hit issues; with RAM, recent plugin versions map the state volume automatically — if it fails, **restart the VM** and retry.
3. Change something in the guest, then **Rollback** to confirm.
4. Optional: **Clone** from snapshot.

Array schedules may also show as **`nimble*`** entries in the tree after sync.

![Take snapshot](images/pve-vm-snapshot-create-dialog.png)  
![Snapshot task OK](images/pve-snapshot-task-viewer-success.png)  
![Snapshot tree](images/pve-vm-snapshots-nimble-tree.png)

**Volume collections:** optional `nimble_volume_collection` in storage config adds **new** volumes to a Nimble collection. Putting disks into a **sync-replicated** collection by hand is **not** tested with PVE snapshots — use async protection or a separate DR collection.

---

## 9. Live migration (optional)

With shared Nimble storage and multipath, **VM → Migrate** while running should work. Check the task log on the target node.

![Migrate dialog](images/pve-migrate-vm-dialog.png)  
![Migration success](images/pve-migration-task-viewer.png)

---

## Restore (when you need it)

| Snapshot source | What to do |
|-----------------|------------|
| **Proxmox UI** | **VM → Snapshots → Rollback** (whole VM). Single-disk only: clone from snap or restore that LUN in Nimble UI. |
| **Array schedule / Nimble UI** | Clone snap to a new volume, or in-place **Restore** with VM **stopped**. PVE-side names often look like `vm-100-disk-0.snap-<name>`. |

REST restore example and offline requirements: [API_VALIDATION.md](API_VALIDATION.md) (snapshot rollback).

---

## Quick reference

| Task | Command |
|------|---------|
| Add storage | `pvesm add nimble …` (see step 6) |
| Debug | `pvesm set <id> --nimble_debug 1` or `NIMBLE_DEBUG=1 pvesm list <id>` |
| Sessions | `sudo iscsiadm -m session` |
| Multipath | `sudo multipath -ll` |

---

## Troubleshooting

| Symptom | Check |
|---------|--------|
| Storage unavailable | Plugin on **all** nodes; `systemctl restart pvedaemon` after install |
| No discovery IPs | Nimble subnets + `discovery_ip`; or `nimble_iscsi_discovery_ips` in storage config |
| No LUN after create | `iscsiadm -m session`; ACL / initiator group; data network |
| `iscsiadm` exit **15** in debug | Usually already logged in — OK if disks work |
| RAM snapshot fails | Restart VM; try without RAM; [GitHub issue](https://github.com/brngates98/pve-nimble-plugin/issues) |
| Sync repl + volcoll + PVE snap | Avoid mixing; see [README](../README.md#troubleshooting) |

Full table: [README troubleshooting](../README.md#troubleshooting).
