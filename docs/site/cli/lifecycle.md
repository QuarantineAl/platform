---
title: Lifecycle commands
description: quarantine init, start, status, version, upgrade and destroy.
sidebar:
  order: 1
---

These commands manage the environment as a whole. Run them on the VM, as root.

| Command | Changes things? |
|---|---|
| `quarantine init` | Yes: creates keys, secrets and host config |
| `quarantine start` | Yes: reconciles every container in the environment |
| `quarantine status` | No |
| `quarantine version` | No |
| `quarantine upgrade` | Yes: pulls `main` and runs `start` |
| `quarantine destroy` | Yes, destructive: removes every container |

## init

```text
quarantine init [--domain DOMAIN] [--env NAME] [--email EMAIL] [--cf-token TOKEN] [--age-key-file PATH]
```

One-time setup of an environment on a host. Already done on dev and prod; you
only run it when [standing up a new environment](/platform/guides/environments/new-environment/)
or rebuilding a host.

| Flag | Meaning | Required non-interactively |
|---|---|---|
| `--env NAME` | Environment name, `^[a-z][a-z0-9-]*$`. Prompted with default `prod`. | Yes |
| `--domain DOMAIN` | Base domain, e.g. `dev.quarantine.al` | Yes |
| `--email EMAIL` | ACME account email; also becomes Zitadel's first admin user's email | Yes |
| `--cf-token TOKEN` | Cloudflare API token (Zone / DNS / Edit) for the DNS-01 challenge | Only when new secrets are generated |
| `--age-key-file PATH` | Restore an existing age private key from a file | Only when restoring and no key is on the host |
| `-h`, `--help` | Print init's usage | |

What it does, in order:

1. Takes the environment lock.
2. Uses `/opt/quarantine/keys/age-<env>.txt` if it exists; otherwise restores
   it from `--age-key-file`, or asks `[g]enerate new or [r]estore from backup?`.
3. Copies `environments/_template/{compose,manifest}.yaml` to
   `environments/<env>/` if that directory does not exist.
4. If `secrets.sops.yaml` exists, decrypts it and checks every required key
   is filled (restore). Otherwise writes the age public key into `.sops.yaml`
   and generates fresh secrets (Postgres admin password, Zitadel masterkey,
   admin and DB passwords, oauth2-proxy cookie secret, and the Cloudflare
   token you supply).
5. Writes `/opt/quarantine/quarantine.yaml` (mode 0600).
6. Warns (never fails) if `<domain>` or `auth.<domain>` do not resolve to this
   host's public IP.

```bash title="Non-interactive init for a new environment (new host)"
quarantine init --env acme --domain acme.example.net \
  --email ops@example.com --cf-token "$CF_API_TOKEN"
```

```text title="Expected tail of the output"
[quarantine] generated and encrypted secrets for 'acme'
[quarantine] remember to git add/commit/push environments/acme/secrets.sops.yaml (and .sops.yaml if this is the first environment of its name)
[quarantine] wrote /opt/quarantine/quarantine.yaml
[quarantine] init complete for environment 'acme'. Next: quarantine start
```

:::danger[Back up the age key]
`/opt/quarantine/keys/age-<env>.txt` is the only key that decrypts the
environment's secrets. There is no recovery if it is lost. Copy it somewhere
durable and access-controlled immediately after `init` generates it.
:::

Errors:

| Error | Fix |
|---|---|
| `--env is required when not running interactively` (also `--domain`, `--email`, `--cf-token`) | Pass the flag |
| `invalid environment name 'Dev'` | Lowercase letters, digits, hyphens; start with a letter |
| `secrets.sops.yaml is missing or has placeholder values for: ...` | The backup predates the current schema; add the missing keys |
| `failed to decrypt secrets for '<env>'` | The restored key is the wrong one |

## start

```bash
quarantine start
```

The idempotent reconcile. Safe to run at any time; a second run changes
nothing. In order it:

1. Takes the environment lock and creates the `edge` network if missing.
2. Decrypts secrets and regenerates `environments/<env>/.env`.
3. Starts Traefik, then Postgres (waiting for each to be healthy), ensures
   Zitadel's own database, then starts `zitadel-api` and `zitadel-login`.
4. Forces Zitadel's `loginV2.required` instance feature off (the Console's
   redirect into Login V2 is broken upstream).
5. Starts observability if `observability: true` in the manifest.
6. Starts every `runner*` service, unless `QUARANTINE_SKIP_RUNNER=true`
   (set only by `deploy-platform.yml`, which runs *inside* a runner).
7. Logs Docker into `ghcr.io` if `core.ghcr.pull_token` is set.
8. For each app in the manifest: creates its Postgres database
   (`needs_db`) and its Zitadel OIDC application (`needs_oidc`), generating
   any `generated_secrets`, then starts all of them in one `up -d`.
9. Stops any catalog app that is running but no longer in the manifest.

```text title="Typical output on dev (abridged)"
[quarantine] edge network already exists
[quarantine] generated /opt/quarantine/repo/environments/dev/.env
[quarantine] starting traefik
[quarantine] quarantine-traefik is healthy
...
[quarantine] observability not enabled for 'dev' — skipping (set 'observability: true' in environments/dev/manifest.yaml to enable)
[quarantine] starting ci runner pool: runner
[quarantine] Zitadel OIDC application for 'lazzaretto' already provisioned (client_id persisted) — skipping
[quarantine] starting apps: kujtime lazzaretto qualitech searxng delivery-note-ai
[quarantine] quarantine start complete for environment 'dev'
```

:::caution
`start` recreates any container whose configuration changed, including core
services. On prod that means a brief interruption of every app, and it
recreates the CI runner unless `QUARANTINE_SKIP_RUNNER=true`. App deploys from
CI never call it; see [Deploys](/platform/guides/apps/deploy/).
:::

If `start` printed `secrets.sops.yaml was updated — remember to git add/commit/push ...`,
commit that file (see [Secrets](/platform/guides/secrets/)).

| Error | Fix |
|---|---|
| `timed out after 120s waiting for quarantine-zitadel-api to be healthy` | `docker logs quarantine-zitadel-api` |
| `secret '.core...' is empty or still a template placeholder` | The secrets file is incomplete; fill the key |
| `failed to read catalog.yaml — check for syntax errors` | Fix the YAML (merge markers, indentation) |

## status

```bash
quarantine status
```

Read-only. Runs `docker compose ps` for the environment project with every
catalog profile and `observability` enabled, so it shows everything the
environment could run. It does **not** show per-tenant instances or PR
sandboxes (separate Compose projects); use `quarantine tenant list` and
`docker ps` for those.

```text title="Output on dev, 2026-10-23 (abridged)"
[quarantine] environment: dev  domain: dev.quarantine.al
time="..." level=warning msg="The \"N8N_ENCRYPTION_KEY\" variable is not set. Defaulting to a blank string."
NAME                                       IMAGE                                          SERVICE                         STATUS
quarantine-delivery-note-ai-web            ghcr.io/quarantineal/delivery-note-ai-web:...  delivery-note-ai-web            Up About an hour (healthy)
quarantine-dev-runner-1                    myoung34/github-runner:latest                  runner                          Up About an hour
quarantine-kujtime                         ghcr.io/quarantineal/kujtime:dev               kujtime                         Up 33 hours (healthy)
quarantine-lazzaretto-backend              ghcr.io/quarantineal/lazzaretto-backend:dev    lazzaretto-backend              Up 33 hours (healthy)
quarantine-oauth2-proxy-lazzaretto         quay.io/oauth2-proxy/oauth2-proxy:v7.15.3      oauth2-proxy-lazzaretto         Up 22 hours
quarantine-postgres                        postgres:17.10-alpine                          postgres                        Up 33 hours (healthy)
quarantine-traefik                         traefik:v3.7.9                                 traefik                         Up 33 hours (healthy)
quarantine-zitadel-api                     ghcr.io/zitadel/zitadel:v4.16.1                zitadel-api                     Up 33 hours (healthy)
quarantine-zitadel-login                   ghcr.io/zitadel/zitadel-login:v4.16.1          zitadel-login                   Up 33 hours (healthy)
```

The `variable is not set` warnings come from apps in the compose graph that are
not in this environment's manifest (n8n on dev); they are harmless.

## version

```bash
quarantine version
```

Read-only. Prints `git describe --tags --dirty --always` of the checkout the
binary lives in. There are no tags yet, so it is a short commit SHA, with
`-dirty` if the checkout has uncommitted changes.

```text title="Output on dev, 2026-10-23"
db82646
```

## upgrade

```bash
quarantine upgrade
```

Updates the platform code on the host and applies it:

1. Checks that the configured repo and the CLI's own checkout are the same
   directory, and that it is on branch `main`.
2. `git fetch origin main` and `git merge --ff-only origin/main`.
3. Re-executes itself as `quarantine start`.

This is what `.github/workflows/deploy-platform.yml` runs. It fails if the
checkout has local changes that conflict, typically a generated secret nobody
committed; see [Secrets](/platform/guides/secrets/#committing-generated-secrets).

| Error | Fix |
|---|---|
| `expected /opt/quarantine/repo to be on branch 'main' (found '...')` | `git -C /opt/quarantine/repo checkout main` |
| `configured repo (...) is not the same checkout as this CLI's own location (...)` | Fix `repo:` in `quarantine.yaml` |
| `Not possible to fast-forward` / local changes would be overwritten | Commit what the host changed (via a PR), then retry |

## destroy

```bash
quarantine destroy
```

:::danger
Stops and removes **every container** of the environment (core services,
apps, runners, observability). Every app on that VM goes down until the next
`quarantine start`. Volumes are kept, so data survives, but use this only for
a host migration or a full rebuild.
:::

It asks you to type the environment name:

```text
[quarantine] WARN: this stops and removes all containers for environment 'dev' (volumes are preserved)
Type the environment name to confirm destruction (type 'dev' to confirm): dev
[quarantine] environment 'dev' destroyed (volumes preserved) — 'quarantine start' recreates containers from the same state
```

Per-tenant instances and PR sandboxes are separate projects and are not
touched.
