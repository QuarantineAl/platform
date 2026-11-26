---
title: quarantine backup
description: Set up, run, check and restore backups of an environment's data.
sidebar:
  order: 8
---

Saves an environment's volumes, Postgres and SQLite databases to a
repository off the VM. See [Backups and restore](/platform/guides/backups/)
for what is saved and the restore steps.

| Command | Mutates |
|---|---|
| `backup init <repository>` | `secrets.sops.yaml` (first time), `quarantine.yaml`, an SSH key, a systemd timer |
| `backup run` | adds a backup, removes old ones |
| `backup list` | nothing |
| `backup status` | nothing |
| `backup restore <snapshot\|latest> <dir>` | writes into `<dir>` only |
| `backup restore-volume <snapshot\|latest> <volume>` | replaces that volume's content |

```bash title="prod VM"
quarantine backup status
```

```text title="Output"
last successful backup: 2026-11-27T02:41:10Z (6 hour(s) ago)
repository: rest:http://10.0.0.1:8000/prod
```

`status` exits with an error when the last good backup is older than 26
hours, so it can be used as a health check.

## Repository

`<repository>` is a restic REST server (`rest:http://host:8000/name`), an
SFTP address (`sftp:user@host:/path`) or a path on the host. The data is encrypted before it leaves the VM, with the
password at `.core.backup.password` in `secrets.sops.yaml`.

## Optional settings

In `/opt/quarantine/quarantine.yaml`:

```yaml
backup:
  repository: rest:http://10.0.0.1:8000/prod
  ping_url: https://status.example.com/api/push/abc   # fetched after each good run
  exclude_volumes: ["pr-*"]                           # volume name patterns to skip
  keep_daily: 7                                       # how many backups to keep
  keep_weekly: 4
  keep_monthly: 0
```

## Notes

- `run` takes its own lock, so it never blocks a deploy and two runs never overlap.
- restic and SQLite run from Docker images; nothing is installed on the host.
- `restore-volume` refuses to run while a container uses the volume.
