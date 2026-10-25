---
title: quarantine tenant
description: One Lazzaretto instance per tenant - onboarding, membership, lifecycle, upgrades and purge.
sidebar:
  order: 5
---

A **tenant** is a dedicated Lazzaretto instance (backend, frontend and its
own oauth2-proxy) for one person or a small team, at
`https://<tenant>-lazzaretto.<domain>` (API at
`https://<tenant>-lazzaretto-api.<domain>`). Tenants run on prod today
(`lumistry`, `qualitech`, `santec` on 2026-10-23); dev has none.

Access to a tenant needs **two** things, keyed by email:

1. **Identity**: a Zitadel user ([`quarantine user add`](/platform/cli/user/)).
2. **Membership**: the email in the tenant's allowlist,
   `/opt/quarantine/tenants/<env>/<tenant>/authenticated-emails.txt`.

Neither implies the other. A user who is not a member signs in and then gets
403 at the tenant's URL; an allowlist entry with no Zitadel user does nothing.

:::caution[Members share a container]
Members of one tenant share one container and one SQLite file, so each
member's coding agent can reach the others' session workspaces and CLI tokens.
Adding a member is a trust decision. People who should not see each other's
data get separate tenants (the default).
:::

| Command | Mutates | Env lock |
|---|---|---|
| `tenant onboard <tenant> --email <e> [--invite] [--given-name G] [--family-name F] [--version V] [--concurrency N]` | user + tenant | yes |
| `tenant add <tenant> --email <e>[,<e>...] [--version V] [--concurrency N]` | allowlist, redirect URI, containers | yes |
| `tenant list [--json]` | nothing | no |
| `tenant show <tenant> [--json]` | nothing | no |
| `tenant start\|stop\|restart <tenant>` | containers | no |
| `tenant logs <tenant> [service...]` | nothing | no |
| `tenant upgrade <tenant> [version]` | containers, `tenant.conf` | no |
| `tenant upgrade-all [version]` | every tenant's containers | no |
| `tenant remove <tenant>` | removes containers (data kept) | no |
| `tenant purge <tenant> [--yes]` | **deletes data** | yes |
| `tenant member add <tenant> <email>` | allowlist | no |
| `tenant member remove <tenant> <email>` | allowlist | no |
| `tenant member list <tenant> [--json]` | nothing | no |

Tenant names: `^[a-z][a-z0-9-]*$`, at most 40 characters.

## tenant onboard

Creates the Zitadel user, then the tenant. Equivalent to `user add` followed by
`tenant add`. Takes exactly one `--email`; use `tenant add --email a,b` or
`tenant member add` for teams.

```bash title="Give Alice her own tenant on prod (prod VM)"
quarantine tenant onboard alice --email alice@example.com --invite \
  --given-name Alice --family-name Example
```

Hand Alice the invite code it prints (no SMTP), and the URL
`https://alice-lazzaretto.quarantine.al`.

## tenant add

```text
quarantine tenant add <tenant> --email <e>[,<e>...] [--version V] [--concurrency N]
```

Three steps, each idempotent, so it is safe to re-run after a failure:

1. Writes the allowlist and `tenant.conf` (`version`, `concurrency`).
2. Registers `https://<tenant>-lazzaretto.<domain>/oauth2/callback` on the
   shared `lazzaretto` Zitadel application.
3. Brings up Compose project `quarantine-lazzaretto-<tenant>` and waits for
   the backend to be healthy and the oauth2-proxy sidecar to stay up.

| Flag | Default | Meaning |
|---|---|---|
| `--email` | required | Comma-separated members |
| `--version` | value in `tenant.conf`, else the environment name (`prod`) | Lazzaretto image tag |
| `--concurrency N` | `2` | Concurrent agent turns; also sets the memory limit: `100 + 450*N + 700*ceil(N/4) + 100` MiB (1350 MiB at 1, 1800 at 2, 2700 at 4), swap equal to that again, 2 CPUs, 512 pids |

The tenant's `LAZZARETTO_CREDENTIALS_KEY` is generated on first run and stored
under `.tenants["<tenant>"]` in `secrets.sops.yaml`: commit it. The command
warns if any member has no Zitadel user, and if the memory limits of all
Lazzaretto backends on the host exceed 85% of RAM plus swap minus 2.5 GiB.

```text title="Expected tail"
[quarantine] tenant 'alice' is up at https://alice-lazzaretto.quarantine.al
```

## tenant list

Read-only. Derived live from Docker plus the tenant directories (there is no
registry file).

```text title="Output on prod, 2026-10-23"
TENANT	STATUS	VERSION	MEMBERS	URL
lumistry	running	288ec78058114ce5cfd9283241214aedc81d4f63	1	https://lumistry-lazzaretto.quarantine.al
qualitech	running	288ec78058114ce5cfd9283241214aedc81d4f63	1	https://qualitech-lazzaretto.quarantine.al
santec	running	288ec78058114ce5cfd9283241214aedc81d4f63	1	https://santec-lazzaretto.quarantine.al
```

On dev: `[quarantine] no tenants provisioned in environment 'dev'` (and
`{"tenants":[]}` with `--json`). `STATUS` is the backend container state, or
`absent` if a half-finished `add` left a directory but no containers.

## tenant show

```text title="quarantine tenant show santec (prod, member replaced)"
tenant: santec
url: https://santec-lazzaretto.quarantine.al
apiUrl: https://santec-lazzaretto-api.quarantine.al
status: running
version: 288ec78058114ce5cfd9283241214aedc81d4f63
project: quarantine-lazzaretto-santec
volume: quarantine-lazzaretto-santec_lazzaretto-data
allowlist: /opt/quarantine/tenants/prod/santec/authenticated-emails.txt
concurrency: 2
members: - member@example.com
```

## tenant start / stop / restart / logs

```bash
quarantine tenant stop alice        # containers kept
quarantine tenant start alice       # re-runs the full bring-up from tenant.conf
quarantine tenant restart alice
quarantine tenant logs alice lazzaretto-backend   # compose service names; omit for all
```

`tenant logs` passes everything after the tenant name straight to
`docker compose logs`, so flags work too: `quarantine tenant logs alice -f --tail 100 lazzaretto-backend`.

## tenant upgrade / upgrade-all

```text
quarantine tenant upgrade <tenant> [version]
quarantine tenant upgrade-all [version]
```

Tenants are outside `quarantine start`'s reconcile loop, so a new image reaches
them only through these (CI runs `tenant upgrade-all <sha>` after each prod
deploy, see [Deploys](/platform/guides/apps/deploy/)). Both write the version to
`tenant.conf`, pull the image and recreate the tenant, waiting for health.
`upgrade-all` goes one tenant at a time and stops at the first failure; tenants
already upgraded stay upgraded.

```bash title="Roll every prod tenant to a known build (prod VM)"
quarantine tenant upgrade-all 288ec78058114ce5cfd9283241214aedc81d4f63
```

Recreating a backend kills any agent turn in progress there.

## tenant member add / remove / list

```bash title="prod VM"
quarantine user add bob@example.com --invite
quarantine tenant member add alice bob@example.com
quarantine tenant member list alice
quarantine tenant member remove alice bob@example.com
```

No restart: the allowlist is rewritten in place and oauth2-proxy reloads it.
A removed member is refused immediately; their rows stay in the tenant's
database, invisible to the others.

## tenant remove

```bash
quarantine tenant remove alice
```

Runs `docker compose down` **without** `-v`: containers go, the data volume,
allowlist and redirect URI stay. `quarantine tenant start alice` brings it back.

## tenant purge

```text
quarantine tenant purge <tenant> [--yes]
```

:::danger[Irreversible]
Deletes the tenant's data volume (sessions, profiles, CLI accounts, stored
credentials), its redirect URI, its allowlist directory, and blanks its
credentials key in `secrets.sops.yaml`. Without `--yes` it asks you to type the
tenant name. Zitadel users are **not** deleted; use `quarantine user remove`.
:::

```bash
quarantine tenant purge alice
```

```text
[quarantine] WARN: purge DELETES tenant 'alice's data volume — its sessions, profiles, CLI accounts and stored credentials. This cannot be undone.
Type the tenant name to confirm (type 'alice' to confirm): alice
...
[quarantine] tenant 'alice' purged: containers, data volume, allowlist and redirect URI are all gone
```

Commit `secrets.sops.yaml` afterwards (the key was blanked).

## Common problems

| Symptom | Cause | Fix |
|---|---|---|
| Tenant URL answers 404 | oauth2-proxy sidecar crash-looping, usually an unreadable allowlist | Allowlist must be mode 0644 in a 0755 directory; `docker logs quarantine-oauth2-proxy-<tenant>-lazzaretto` |
| User signs in, then 403 | Email not in the allowlist, or email not verified | `tenant member list`, `user show` ([Verify email](/platform/guides/users/verify-email/)) |
| `no tenant 'x' in environment 'dev'` | Wrong VM or name | Tenants live on prod |
