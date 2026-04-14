# Claude prompt: validate plugin logic vs HPE Nimble API

Copy everything inside the **fenced block** below into a new Claude conversation (or Claude Code task). Replace `<REPO_ROOT>` if paths need to be absolute on your machine.

---

## Prompt (copy from here)

```
You are validating the Proxmox VE **pve-nimble-plugin** (Perl) for **correctness against official HPE Nimble Storage REST API documentation**, not against guesses.

### Ground truth (read first, in order)

1. **In-repo** (treat as the maintainer’s API digest; cross-check against HPE where it disagrees):
   - `docs/NIMBLE_API_REFERENCE.md` — endpoints, `data` envelope, restore vs clone, volume fields.
   - `docs/API_VALIDATION.md` — inventory of every `nimble_api_call` usage and claimed status.
2. **Implementation**:
   - `NimbleStoragePlugin.pm` — all REST paths, request bodies, response parsing, and host-side workflows (iSCSI, ACL, rollback, delete, clone, `status()`, import/export).
3. **Project rules** (if present):
   - `.cursor/rules/api-compatibility.mdc` — required validation steps.

### Official HPE sources (must consult)

- **REST API index:** https://support.hpe.com/docs/display/public/nmtp352en_us/wzk1480348939804.html  
  Open the **object set** pages linked from the index for: **tokens**, **initiator_groups**, **initiators**, **volumes**, **snapshots**, **access_control_records**, **pools**, **arrays**, **subnets**, **network_interfaces**, **volume_collections** (and any other object set the plugin calls).
- Use the **operation** pages (Create / Read / Update / Delete / RPC) for each HTTP method the plugin uses. Prefer the same major doc generation as **5.1.1.0** if multiple versions exist; note any version skew you find.

**Secondary reference (naming and fields, not a substitute for HPE):**  
[HPE Nimble Python SDK](https://github.com/hpe-storage/nimble-python-sdk) generated `nimbleclient/v1/api/*.py` — useful for parameter names and volume attributes (e.g. `force`, `online`, `multi_initiator`); **confirm every critical behavior in HPE’s own REST docs.**

### What to validate

For **each** distinct REST call pattern in `NimbleStoragePlugin.pm` (path + method):

| Check | Question |
|--------|-----------|
| Path | Exact path and spelling (e.g. `volumes/:id/actions/restore` vs wrong variants). |
| Method | GET / POST / PUT / DELETE matches HPE. |
| Envelope | Request body uses `{ "data": { ... } }` where HPE requires it; headers (`X-Auth-Token`) correct for tokens. |
| Parameters | Mandatory fields present; types correct (e.g. size in **MiB**, `base_snap_id` for restore/clone); optional fields documented. |
| Response | Plugin reads `data` wrapper and list shapes (`items`, arrays) per HPE; note any fragile fallbacks. |
| Errors | Documented Nimble codes relevant to plugin behavior (`SM_vol_not_offline_on_restore`, `SM_vol_has_connections`, `SM_http_conflict`, `SM_eperm`, etc.) and whether plugin handling matches HPE semantics. |

### Workflows to trace end-to-end in code (call graph + API sequence)

1. **Login / token cache / 401 retry**
2. **Activate storage** (discovery subnets, optional global iSCSI login)
3. **Activate/map volume** (ACL, `multi_initiator`, per-volume IQN login, device discovery)
4. **Deactivate/unmap** (`nimble_volume_connection` disconnect path)
5. **Snapshot create / delete / rollback** (`volume_snapshot_rollback` → restore prep → offline → restore → online; `force` on offline if documented)
6. **Clone from snapshot** (POST volumes `clone=true` — must **not** be conflated with restore)
7. **`free_image` / `nimble_remove_volume`** (disconnect, snapshots, offline, DELETE volume)
8. **`status()` / capacity** (pools list vs `pools/:id`, arrays fallback, `pool_name` matching)
9. **Import/export** `raw+size` (PVE contract vs Nimble volume create/resize if any)

For each workflow, list **ordered** REST calls and **host** commands (`iscsiadm`, multipath) separately; flag anything that is host-only vs API.

### Deliverable format

Produce a **structured report**:

1. **Executive summary** — 5–10 bullets: overall alignment, highest-risk gaps, firmware-dependent areas.
2. **Per-endpoint table** — columns: `Plugin usage` | `HPE doc reference` | `Match (Y/N/Partial)` | `Notes / risk`.
3. **Workflow section** — one subsection per numbered workflow above; **sequence diagram** (mermaid optional) or numbered steps; mismatches called out.
4. **Action list** — concrete changes to `NimbleStoragePlugin.pm` and/or `docs/API_VALIDATION.md` / `docs/NIMBLE_API_REFERENCE.md` if HPE contradicts current behavior; mark each **Must fix** vs **Verify on array**.
5. **Explicit unknowns** — where HPE docs are silent or ambiguous; recommend **array version** and **manual test** to run.

### Rules

- Do **not** assume Nimble behavior from generic iSCSI knowledge alone; tie claims to **HPE pages** or mark as **inference**.
- If the in-repo `NIMBLE_API_REFERENCE.md` conflicts with HPE, **HPE wins** and note the doc bug.
- Cite HPE URLs (full `https://...`) for each object set / operation you rely on.

When done, suggest whether `docs/API_VALIDATION.md` “Status” column entries should change and why.
```

---

## How to use

- Paste the prompt into Claude with **repository access** (e.g. Claude Code with the repo open, or upload/archive the plugin tree).
- For best results, attach or allow reading **`NimbleStoragePlugin.pm`** and **`docs/*.md`** in full; the file is large—use a tool-enabled session or split reads by section if needed.
- After Claude finishes, apply **Must fix** items in code and update **`docs/API_VALIDATION.md`** per `.cursor/rules/api-compatibility.mdc`.
