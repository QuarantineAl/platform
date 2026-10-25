---
title: Stand up a new environment
description: Take a fresh Debian/Ubuntu host to a running quarantine environment - install.sh, init, start, verification and backups.
sidebar:
  order: 1
---

Use this to build a new environment (a client install, a test host) or to
rebuild dev or prod on new hardware. Size the VM first: [VM sizing](/platform/guides/environments/vm-sizing/).

## Prerequisites

| Requirement | Why |
|---|---|
| Debian/Ubuntu host, x86_64 or arm64, root access | `install.sh` uses apt and must run as root |
| Ports 80 and 443 free | Traefik binds both |
| A domain whose DNS is on Cloudflare | Certificates use the DNS-01 challenge |
| A Cloudflare API token, Zone / DNS / Edit on that zone only | Passed to `init` |
| DNS A records for `<domain>` and `*.<domain>` (or each subdomain) pointing at the host | For traffic to arrive; certificates issue even before this |

## 1. Install

```bash title="New host, as root"
curl -fsSL https://raw.githubusercontent.com/QuarantineAl/platform/main/install.sh | sudo bash
```

It installs `git curl age ca-certificates` from apt, Docker (via
get.docker.com, only if missing), checksum-verified `sops` 3.13.3 and `yq`
4.53.3, checks for `flock`, clones the repo to `/opt/quarantine/repo` (or
fast-forwards an existing clone) and links `/usr/local/bin/quarantine`.

| Variable (set on the `sudo ... bash` side) | Default |
|---|---|
| `QUARANTINE_REPO_URL` | `https://github.com/QuarantineAl/platform.git` |
| `QUARANTINE_INSTALL_DIR` | `/opt/quarantine/repo` |
| `QUARANTINE_BIN_LINK` | `/usr/local/bin/quarantine` |

Stay root for every `quarantine` command afterwards.

## 2. Init

```bash title="Brand-new environment"
quarantine init --env acme --domain acme.example.net --email ops@example.com --cf-token "$CF_API_TOKEN"
```

```bash title="Rebuild an existing environment (dev/prod) on a new host"
quarantine init --env dev --domain dev.quarantine.al --email <admin email> \
  --age-key-file /root/age-dev.txt      # the backed-up key; delete this copy afterwards
```

All flags are described in [Lifecycle commands](/platform/cli/lifecycle/#init).

:::danger[Back up the age key now]
Copy `/opt/quarantine/keys/age-<env>.txt` to durable, access-controlled
storage before doing anything else. Without it the environment's secrets
cannot be decrypted, and there is no recovery.
:::

For a new environment, commit `environments/<env>/` and `.sops.yaml` through a
pull request ([Secrets](/platform/guides/secrets/#committing-generated-secrets)).

## 3. Start

```bash
quarantine start
```

The first run is slow (Zitadel runs its migrations). It brings up Traefik,
Postgres and Zitadel; the manifest is empty for a new environment.

## 4. Verify

```bash
quarantine status
curl -s https://auth.acme.example.net/.well-known/openid-configuration | head -c 200
```

Open `https://auth.<domain>` in a browser: a valid certificate and the Zitadel
login page. The first admin is `admin` with the email you passed to `init`;
its password is `core.zitadel.admin_password` in the secrets
([Secrets](/platform/guides/secrets/#read-one-value)).

## 5. Add apps and a runner

- Apps: `quarantine app add <name>` then `quarantine start`
  ([quarantine app](/platform/cli/app/)).
- CI runner: add `- path: ../../infra/ci/github-runner/compose.yaml` to
  `environments/<env>/compose.yaml`, set `core.github_runner.pat` (a GitHub PAT
  that can register org runners), then `quarantine start`. The runner registers
  with label `quarantine-<env>`.
- Private images: set `core.ghcr.pull_username` / `pull_token` (read:packages).

## What to back up

| What | How |
|---|---|
| `/opt/quarantine/keys/age-<env>.txt` | Offline, immediately. The only irreplaceable piece. |
| `secrets.sops.yaml`, `manifest.yaml`, `compose.yaml` | Already in git |
| Docker volumes (Postgres, Zitadel state via Postgres, app data) | Not handled by the platform; back up like any Docker volume |
| `/opt/quarantine/tenants/` | Allowlists and tenant settings (prod) |
