---
name: Bug report
description: Report a bug or unexpected behavior with the PVE Nimble Storage plugin
about: Report a bug or unexpected behavior with the PVE Nimble Storage plugin
title: "[Bug]: "
labels: ["bug"]
---

## Describe the bug

A clear, concise description of what the bug is.

## To reproduce

1. Steps to reproduce (e.g. add Nimble storage, create VM disk, …)
2. …
3. …

## Expected behavior

What you expected to happen.

## Actual behavior

What actually happened (error message, wrong result, crash, etc.). If there is an error, paste the full message.

## Environment

- **Plugin version:** (e.g. from `dpkg -l libpve-storage-nimble-perl` or manual install)
- **Proxmox VE version:** (e.g. 8.2, 9.0 — from `pveversion -v` or Web UI)
- **Nimble array / OS:** (e.g. NimbleOS version if known)
- **Cluster or single node?**

## Storage configuration (optional)

If relevant, paste the Nimble block from `/etc/pve/storage.cfg` (you can redact password). Example:

```text
nimble: mystore
  address https://nimble.example.com
  username admin
  content images
  ...
```

## Logs / diagnostics (optional)

- Output of `NIMBLE_DEBUG=2` if you ran a command with debug (see [Debug logging](https://github.com/brngates98/pve-nimble-plugin#debug-logging) in README)
- Any relevant lines from `journalctl -u pvedaemon` or Proxmox task log

## Additional context

Any other context, screenshots, or details that might help.
