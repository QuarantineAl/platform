# quarantine

`quarantine` is a self-hosted platform bootstrapper: a CLI plus a Docker
Compose graph that stands up TLS-terminated edge routing, OIDC identity,
shared Postgres, and observability on a single host, then reconciles a
catalog of apps on top of it. It is **not** a Kubernetes/Helm tool and
**not** a PaaS — there is no scheduler, no multi-node orchestration, no
managed control plane. Everything runs as Docker Compose projects on the
host(s) you point it at, driven by one `quarantine.yaml` config file and a
per-environment `manifest.yaml`. If you want Kubernetes, this isn't it.

## Prerequisites

Before `quarantine init`, you need:

- A domain you control, delegated to **Cloudflare DNS**. Traefik issues
  certificates via Cloudflare's DNS-01 challenge, not HTTP-01 — so
  certificate issuance succeeds even before any `A` record exists or has
  propagated.
- A **Cloudflare API token** scoped to `Zone:DNS:Edit` for that zone
  (passed via `--cf-token`, or entered at an interactive prompt).
- A target host with ports `80` and `443` free for Traefik. Docker itself
  is handled for you by `install.sh` (see below).

Supported install target: Debian/Ubuntu (`apt-get`), x86_64 or arm64,
`install.sh` must run as root.

## Quickstart

Three commands: install, init, start.

**1. Install.** This clones the repo to `/opt/quarantine/repo` and
symlinks `bin/quarantine` onto `PATH`.

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_ORG/quarantine/main/install.sh | sudo bash
```

This repo has no real remote yet (`YOUR_ORG` above is a literal
placeholder). Once it has a home, either edit the default in `install.sh`
or override it at install time:

```bash
curl -fsSL <raw-url-to-install.sh> | \
  sudo QUARANTINE_REPO_URL=https://github.com/your-actual-org/quarantine.git bash
```

The env var has to go on the `sudo ... bash` side of the pipe, not before
`curl` — `curl` is the only thing that would ever see a variable prefixed
onto its own invocation, and it doesn't care about `QUARANTINE_REPO_URL`;
`install.sh`'s own `${QUARANTINE_REPO_URL:-...}` expansion runs inside the
`bash` process that `sudo` execs to interpret the piped script, so that's
where the variable actually needs to be set.

`QUARANTINE_INSTALL_DIR` (default `/opt/quarantine/repo`) and
`QUARANTINE_BIN_LINK` (default `/usr/local/bin/quarantine`) are also
overridable via env var.

**2. Init.** One-time, interactive setup for a named environment
(`prod` if you just hit enter):

```bash
quarantine init --domain example.com --env prod --email you@example.com --cf-token <cloudflare-token>
```

Every flag can be omitted and answered at an interactive prompt instead
— `--domain`, `--env`, `--email`, and `--cf-token` are only *required* up
front when running non-interactively (CI, scripted installs). `--age-key-file
PATH` is for restoring an environment onto a new host from an existing
`secrets.sops.yaml` + age key pair; leave it out to generate a brand new
environment. Run `quarantine init --help` for the full flag reference.

`init` runs preflight checks, creates `environments/<env>/` from
`environments/_template/` (never touches an existing one), generates or
restores that environment's encrypted `secrets.sops.yaml`, and writes
`/opt/quarantine/quarantine.yaml`.

One thing worth knowing before you run this: the age private key that can
decrypt `secrets.sops.yaml` lives **outside the repo**, at
`/opt/quarantine/keys/age-<env>.txt`, is never committed, and has no
recovery mechanism. Back it up somewhere durable the moment it's
generated — losing it means losing access to that environment's secrets
forever. See `docs/architecture.md` for the full secrets model.

**3. Start.** Brings the environment up and reconciles it to match its
manifest. Safe to re-run any time — it's an idempotent reconcile, not a
one-shot bring-up:

```bash
quarantine start
```

## What comes up by default

Every `quarantine start` brings up this stack, regardless of which apps
are in the manifest:

| Service | Role | Notes |
|---|---|---|
| Traefik | Edge TLS termination + routing | ACME via Cloudflare DNS-01 |
| Postgres 17.10-alpine | Shared datastore | stock image, one database + role per consumer; not a vendor fork |
| Zitadel v4.16.1 (`zitadel-api` + `zitadel-login`) | OIDC identity provider | backs both the CLI's own provisioners and every catalog app with `needs_oidc: true` |
| SigNoz + otel-collector | Observability | always on — `quarantine start` passes `--profile observability` unconditionally |
| oauth2-proxy | Forward-auth sidecar | present in every environment, but does nothing until a catalog app that needs it (e.g. uptime-kuma) is in the manifest |

One thing that is *not* part of that default set:

- **Redis/Valkey** exists in `infra/data/redis/` and is provisioned ahead
  of need for future first-party apps, but has no consumer yet and isn't
  brought up by `quarantine start` today.

## The app catalog

`catalog.yaml` is the registry of every app `quarantine app add` knows
how to deploy. Today it holds exactly one entry: **uptime-kuma**
(subdomain `status`, no database, OIDC-fronted). Uptime Kuma itself has
no native OIDC support, so the OIDC client this entry provisions is
actually consumed by an oauth2-proxy forward-auth sidecar in front of it,
not by Uptime Kuma directly — public status-page paths stay
unauthenticated, only the admin UI is protected.

```bash
quarantine app add uptime-kuma --version 1.2.3
quarantine app remove uptime-kuma
```

Both commands only edit `environments/<env>/manifest.yaml` on local
disk — they never run `git add`/`commit`/`push` themselves, and they'll
remind you of that every time. Run `quarantine start` afterwards to
reconcile the running containers to match.

Adding a *new* app to the catalog (not just adding an existing catalog
entry to an environment) is a separate, manual process — see
`scripts/new-app.sh` and `docs/adding-an-app.md`. Two apps considered
early on, Immich and Stirling PDF, were deliberately removed from the
catalog as out of scope for now; re-adding a real third-party app later
via `scripts/new-app.sh` is exactly the supported path back to something
like them.

## Command reference

| Command | What it does |
|---|---|
| `quarantine init [--domain D] [--env E] [--email M] [--cf-token T] [--age-key-file P]` | One-time interactive setup for an environment (flags make it scriptable). |
| `quarantine start` | Idempotent reconcile: brings this environment's desired state (core infra + manifest apps) up. |
| `quarantine app add <name> [--version V]` | Adds an app from `catalog.yaml` to this environment's manifest. |
| `quarantine app remove <name>` | Removes an app from this environment's manifest. |
| `quarantine status` | Shows `docker compose ps` across every profile — observability and every catalog app. |
| `quarantine upgrade` | `git pull --ff-only` in the configured repo, then re-execs `quarantine start`. |
| `quarantine destroy` | Requires typing the exact environment name to confirm, then `docker compose down` across every profile. Volumes are explicitly preserved — this is not `-v`. |

Run `quarantine init --help` for init's own full flag reference.

Every mutating command (`init`, `start`, `app add`, `app remove`,
`destroy`) takes an exclusive `flock` over the target environment before
touching anything, so two concurrent invocations against the same
environment can't race and corrupt `manifest.yaml` or
`secrets.sops.yaml`.

Every environment (dev and prod alike) is managed directly by whoever
runs `quarantine app add`/`start` on the host, plus this org's own
self-hosted CI runner for app deploys triggered from GitHub — see
`docs/runners-and-sandboxing.md` for that model.

## Learn more

- [`docs/architecture.md`](docs/architecture.md) — repository layout, the
  secrets model, and the reasoning behind each top-level folder.
- [`docs/adding-an-app.md`](docs/adding-an-app.md) — the full
  `scripts/new-app.sh` workflow for adding a real app to the catalog.
- [`docs/client-install.md`](docs/client-install.md) — the full walkthrough
  for standing up a brand-new environment on a fresh host, from
  `install.sh` through day-2 operations.
- [`docs/runners-and-sandboxing.md`](docs/runners-and-sandboxing.md) — the
  CI runner and PR-sandbox model for both dev and prod.
