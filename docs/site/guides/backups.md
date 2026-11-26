---
title: Backups and restore
description: What the nightly backup holds, where it goes, how to check it ran, and how to get data back.
sidebar:
  order: 15
---

`quarantine backup` saves an environment's data to a place off the VM, every
night. This page covers setting it up, checking it, and restoring.

## What is in a backup

| Data | How it is saved |
|---|---|
| Every named Docker volume | Copied as files |
| The shared Postgres (Zitadel, n8n, ...) | A full SQL dump. The raw `postgres-data` volume is skipped, because copying a running database's files gives a broken copy. |
| Every SQLite database inside those volumes | A clean copy taken through SQLite itself, for the same reason. They are found by file header, so an app does not have to declare anything. |
| `/opt/quarantine/tenants`, `/opt/quarantine/staff`, `quarantine.yaml` | Copied as files |

Not saved: SigNoz volumes (telemetry) and volumes nobody named.

:::danger[Keep the age key somewhere else]
Backups are encrypted with a password stored in `secrets.sops.yaml`. That
file only opens with `/opt/quarantine/keys/age-<env>.txt`, which is **not**
in the backup. If the VM is lost and the age key was only on the VM, no
backup can be read. Keep a copy of the age key off the VM, and not only
inside an app that runs on this platform.
:::

## Set it up (once per environment)

You need a place to send backups to. Either:

- **Another machine over SFTP**: `sftp:backup@10.0.0.1:/srv/backups/prod`
- **A path on this host** that is really another disk: `/mnt/backup-disk/prod`

A folder on the same physical disk as the VM protects against mistakes (a
bad deploy, a deleted volume) but not against that disk failing.

```bash title="On the VM, as root"
quarantine backup init sftp:backup@10.0.0.1:/srv/backups/prod
```

`init` does four things:

1. Generates the backup password and stores it in `secrets.sops.yaml`. This
   changes the file on the host; [commit it through a PR](/platform/guides/secrets/).
2. Saves the repository address in `/opt/quarantine/quarantine.yaml`.
3. For SFTP, creates an SSH key in `/opt/quarantine/keys/backup-ssh/` and
   prints the public half. Add it to the backup user's `authorized_keys` on
   the other machine, then run the same `init` command again.
4. Creates the repository and installs a systemd timer that runs
   `quarantine backup run` every night at 02:30.

Then take the first backup by hand and look at the result:

```bash
quarantine backup run
quarantine backup list
```

## Check that it runs

```bash
quarantine backup status
```

It prints when the last good backup finished and exits with an error if
that is more than 26 hours ago. `systemctl status quarantine-backup.service`
and `journalctl -u quarantine-backup.service` show the last run's output.

To be told when a night is missed, set `backup.ping_url` in
`/opt/quarantine/quarantine.yaml` to a "push" monitor URL (Uptime Kuma has
one). It is fetched after every good backup, so the monitor alerts when the
pings stop.

A run that saves the data but could not dump Postgres or copy a SQLite
database ends with an error and does not count as good. It is still stored,
marked `incomplete` in `backup list`, and `latest` never picks it.

## How long backups are kept

7 daily, 4 weekly and 6 monthly complete backups, plus the last two
incomplete ones. Older ones are removed after each run.

## Restore

Pick a backup with `quarantine backup list`. Use its ID, or `latest` for
the newest complete one.

### One app's volume

```bash
docker stop quarantine-vaultwarden
quarantine backup restore-volume latest quarantine-prod_vaultwarden-data
docker start quarantine-vaultwarden
```

This replaces everything in the volume with the backup's content, including
the clean SQLite copies. It refuses to run while a container uses the
volume, and asks you to type the volume name.

### Postgres

```bash
quarantine backup restore latest /root/restore
docker exec -i quarantine-postgres psql -U postgres -f - < /root/restore/staging/postgres/dumpall.sql
rm -rf /root/restore
```

The dump drops and recreates every database it contains. Stop the apps that
use Postgres first (Zitadel, n8n). One error is expected and harmless:
`current user cannot be dropped`.

### Look inside without changing anything

```bash
quarantine backup restore latest /root/restore
```

Nothing that is running is touched. The directory holds `volumes/`,
`staging/postgres/dumpall.sql`, `staging/sqlite/` and `host/`. It contains
plain data: delete it when done.

### A whole VM

:::caution
This has not been rehearsed end to end. Treat it as an outline and expect
to adapt it.
:::

1. Install the platform and run `quarantine init --age-key-file <your copy>`
   ([New environment](/platform/guides/environments/new-environment/)).
2. `quarantine backup init <the same repository>`. The password comes from
   `secrets.sops.yaml` in git, so the existing repository opens. Over SFTP
   the new VM gets a new SSH key: add it on the backup server first.
3. Start only Postgres, restore the dump into it (see above), then run
   `quarantine start`. Restoring Postgres first matters: `secrets.sops.yaml`
   holds a Zitadel token that only the old Zitadel database knows, so a
   start against an empty database is likely to fail.
4. Stop the apps, restore each volume as above, and `quarantine start` again.

## Test a restore

A backup nobody has restored is a guess. Every few months, restore one
volume on dev (or into a throwaway directory with `backup restore`) and open
the app.
