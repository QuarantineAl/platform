---
title: Add an app
description: Put a new first-party or third-party app into the catalog and run it in an environment.
sidebar:
  order: 1
---

Adding an app has two phases: a **catalog** change in this repository (a pull
request), then enabling it **per environment** with `quarantine app add`.
`scripts/new-app.sh` scaffolds the mechanical part; the rest is a checklist.

## 1. Scaffold

From a checkout of [QuarantineAl/platform](https://github.com/QuarantineAl/platform)
on your laptop (needs Bash 4.4+ and mikefarah `yq`):

```text
scripts/new-app.sh <name> <kind> [--subdomain <sub>] [--image <ref>]

  <name>   catalog/profile name, lowercase, hyphens ok
  <kind>   third-party | first-party
  --subdomain  host prefix, default <name>
  --image      image reference; default CHANGEME-vendor/<name>
               (first-party: ghcr.io/CHANGEME-org/<name>)
```

```bash title="Laptop, in the platform repo, on a branch"
scripts/new-app.sh paperless third-party --subdomain docs
```

It refuses to overwrite an existing `apps/<kind>/<name>/` or catalog entry, and
creates:

- `apps/<kind>/<name>/compose.yaml`: on the `edge` network, Traefik labels for
  `<subdomain>.${DOMAIN}`, image pinned as `${<APP>_VERSION:-CHANGEME}`, a
  placeholder healthcheck, `container_name: quarantine-<name>`, and
  `profiles: [<name>]`.
- A `catalog.yaml` entry with `kind: app`, `needs_db: false`,
  `needs_oidc: false` and a `CHANGEME` note.

## 2. Fill in the details

| Item | What to do |
|---|---|
| Image and healthcheck | Replace every `CHANGEME` in the compose file. Keep `${<APP>_VERSION}` so `--version` works. Use a real healthcheck; `quarantine start` waits on core services, and CI waits on app health. |
| `needs_db: true` | `provisioners/postgres.sh` creates a database and role named after the app (hyphens become underscores) and stores the password at `.apps["<name>"].db_password`. To get it into your container, add `generated_secrets: [{key: db_password, env: DATABASE_PASSWORD_<APP>, generator: alnum32}]` and reference `${DATABASE_PASSWORD_<APP>}` (n8n and kujtime do this). |
| `needs_oidc: true` | Add `oidc_redirect_uris`. `quarantine start` creates the Zitadel application and exports `OIDC_CLIENT_ID_<APP>` / `OIDC_CLIENT_SECRET_<APP>`. Then follow [Add OIDC to an app](/platform/guides/apps/add-oidc/). |
| App-owned random secrets | Declare them under `generated_secrets` (`key`, `env`, `generator: hex32` or `alnum32`). Generated once on first `start`, stored in `secrets.sops.yaml`, never regenerated. |
| Secrets you supply (API keys) | Not generated. Add the key to `environments/_template/secrets.example.yaml` for documentation, set it with `sops` on each VM ([Secrets](/platform/guides/secrets/)), and wire it into `generate_env_file` in `bin/quarantine` (as `ANTHROPIC_API_KEY_KUJTIME` is). |
| Compose graph | Add `- path: ../../apps/<kind>/<name>/compose.yaml` to `environments/_template/compose.yaml` **and** to each existing `environments/<env>/compose.yaml` that should be able to run it. Environment copies are not re-synced from the template. |

`<APP>` is the name upper-cased with hyphens turned into underscores
(`delivery-note-ai` becomes `DELIVERY_NOTE_AI`).

Open a pull request. CI (`lint-and-validate.yml`) runs shellcheck and
`docker compose config` on the template graph.

## 3. Enable it in an environment

After the PR is merged, on the VM (dev first):

```bash title="dev VM"
cd /opt/quarantine/repo && git pull --ff-only     # or wait for deploy-platform.yml
quarantine app add paperless --version 1.2.3
quarantine start
quarantine status
docker logs -f quarantine-paperless
```

`app add` only edits `environments/dev/manifest.yaml`. Commit that change (and
`secrets.sops.yaml` if `start` generated secrets) in a PR, or the host's
checkout stays dirty and the next deploy refuses to run.

Create a DNS record only if `<subdomain>.<domain>` is not already covered by the
wildcard record.

## First-party apps and CI

A first-party app's images are built and deployed by its own repository's
workflows. Two-image apps (backend + frontend) can call the reusable
`deploy-app.yml`; other shapes (qualitech, residences, delivery-note-ai) have
their own workflows. See [Deploys](/platform/guides/apps/deploy/).

## Removing an app from an environment

```bash
quarantine app remove paperless
quarantine start          # stops its containers; volumes and Zitadel app are kept
```
