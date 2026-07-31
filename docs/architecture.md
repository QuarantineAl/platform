# Architecture

This document covers the repository layout and the reasoning behind each
top-level folder. See [Status](#status) at the bottom for exactly what's
built and what's still open.

## Repository layout

```
quarantine/
├── bin/quarantine                 # the CLI
├── install.sh                     # curl-able bootstrapper
├── catalog.yaml                   # app metadata: name, kind, compose path, subdomain, needs_db, needs_oidc
├── .sops.yaml                     # one age key per environment, enforced by path
│
├── infra/                         # shared platform services, grouped by function
│   ├── edge/
│   │   ├── traefik/                 # TLS termination, ACME, routing
│   │   └── oauth2-proxy/            # forward-auth sidecar for apps with no native OIDC
│   ├── identity/
│   │   └── zitadel/                 # OIDC identity provider (API + Login v2 UI)
│   ├── data/
│   │   ├── postgres/                # shared Postgres — one database + role per consumer
│   │   ├── mongo/                   # shared MongoDB — currently Komodo's only consumer
│   │   └── redis/                   # shared Valkey/Redis — no consumer yet, provisioned ahead of need
│   ├── observability/                # compose profile: "observability" (on by default)
│   │   ├── otel-collector/           # OTLP ingestion
│   │   └── signoz/                   # SigNoz UI/API + its ClickHouse telemetry store
│   └── deploy/
│       └── komodo/                   # GitOps continuous deployment (compose profile: "gitops")
│           ├── compose.yaml
│           └── resources/            # Komodo's own Server/Stack definitions, as TOML
│
├── apps/
│   ├── third-party/                 # compose + config only, never source
│   │   └── uptime-kuma/
│   └── first-party/                  # thin deploy fragments referencing ghcr.io images — empty for now
│
├── environments/
│   └── _template/                    # copied by `quarantine init` for new environments
│       ├── compose.yaml               # include: graph assembling infra/ + apps/
│       ├── manifest.yaml              # desired state: which apps/versions are active
│       └── secrets.example.yaml       # PLAINTEXT key-list template — see docs/architecture.md#secrets
│
├── provisioners/                    # postgres.sh, zitadel.sh
├── lib/common.sh                    # shared helpers: log/warn/die, yq/sops wrappers, compose wrapper
├── scripts/
│   └── new-app.sh                   # scaffolds a catalog entry + app fragment
├── docs/
├── .github/workflows/
└── README.md
```

## Rationale per top-level folder

**`bin/`** — the single CLI entry point end users and CI invoke:
`quarantine init/start/app add/app remove/status/upgrade/destroy`. See
`bin/quarantine`'s own top-of-file comment for its conventions
(`QUARANTINE_HOME` resolution, `qcompose()`, secrets threading).

**`install.sh`** — the curl-able bootstrapper referenced by the README
quickstart: installs Docker + compose plugin, git, curl, age, sops, yq,
verifies flock is present, clones this repo, and symlinks
`bin/quarantine` onto `PATH`. Debian/Ubuntu only.

**`catalog.yaml`** — the one place every app (third-party or first-party)
is declared: name, kind, compose path, subdomain, whether it needs the
shared Postgres or an OIDC client. `scripts/new-app.sh` and
`quarantine app add` both read and write this file; nothing app-specific
is hardcoded anywhere else.

**`.sops.yaml`** — enforces one age key per environment by path
(`environments/dev/.*` → dev key, `environments/prod/.*` → prod key).
Ships with placeholder recipient keys clearly marked for replacement;
`quarantine init`'s `ensure_sops_rule` fills these in the first time it
runs for a given environment name (idempotent by the rule's *age value*,
not just path presence, so a placeholder gets healed into the real key
instead of being mistaken for "already configured" — see the comment
above `ensure_sops_rule` in `bin/quarantine`).

**`infra/`** — shared platform services, one function per subfolder,
never more than two levels deep:
- `edge/` — the boundary between the internet and everything else:
  Traefik (TLS/routing) and oauth2-proxy (forward-auth for apps without
  native OIDC).
- `identity/` — Zitadel, the OIDC provider every authenticated app and
  the CLI's own provisioners depend on.
- `data/` — shared, reusable datastores: Postgres (serves Zitadel and any
  future catalog app via one database + role each — plain stock
  `postgres:17.10-alpine`, see the pin note in
  `infra/data/postgres/compose.yaml` for why an earlier Immich-specific
  vector-extension fork was reverted when Immich was deferred out of the
  initial catalog), MongoDB (currently Komodo's backend only), Redis/Valkey
  (no consumer yet, provisioned ahead of need for first-party apps).
  Deliberately excludes datastores that are tightly coupled to a single
  consumer and not meant to be shared — SigNoz's ClickHouse lives inside
  `observability/signoz/`, because reaching into `infra/data/` for it
  would suggest a sharing model that doesn't actually exist.
- `observability/` — OpenTelemetry collection (`otel-collector/`) and
  SigNoz (`signoz/`), split into two fragments sharing one Docker network
  so the collector and the telemetry store it feeds can be reasoned about
  independently. Profile-gated behind `observability`, which every
  environment enables by default via `COMPOSE_PROFILES` — same active
  service set as before this was gated, just now skippable.
- `deploy/` — Komodo, the GitOps continuous-deployment layer. Lives under
  `deploy/` rather than being lumped in with `identity/` or `data/`
  because it's deployment logic, not a service other things call at
  runtime — and because its own resource definitions (which servers/stacks
  it manages) are committed here as TOML, distinct from the compose
  fragment that runs it. Profile-gated behind `gitops` (renamed from
  `komodo` — see [Renamed](#renamed-komodo-profile--gitops) below; the
  Komodo service/container/folder names themselves are unaffected).

**`apps/`** — catalog-managed applications, split by provenance:
`third-party/` holds compose + config for vendored apps and must never
contain source code; `first-party/` will hold thin deploy fragments
referencing `ghcr.io/...` images once this org's own apps are ready to be
listed here — never their source, which lives in each app's own
repository. Only Uptime Kuma ships in the initial catalog today (Immich
and Stirling PDF were deferred — see Status); `first-party/` is empty on
purpose except for a placeholder so the empty directory survives in git.

**`environments/`** — an environment is just a directory: `_template/` is
the only one committed generically; real environments (`dev`, `prod`, a
client's own) get created by `quarantine init` and are themselves
committed once they exist (their `secrets.sops.yaml` is safe in git —
encrypted — and GitOps mode requires Komodo's watched environment
directories to be git-tracked).

**`provisioners/`** — idempotent scripts that ensure a database+role
(`postgres.sh`) or a Zitadel project+OIDC client (`zitadel.sh`) exist for
whatever the manifest currently lists. Both are called from `bin/quarantine`
— never invoked by an operator directly, though both accept the same
`<repo_root> <env> <plaintext_secrets_file> <name>` signature if invoked
standalone (e.g. for debugging).

**`lib/common.sh`** — the one place output helpers, the yq/sops wrappers,
the compose invocation wrapper (`qcompose`), health-gating, and secret
handling live, so every script (CLI, provisioners, `scripts/new-app.sh`)
behaves consistently instead of reimplementing these.

**`scripts/`** — dev/maintenance helpers that are never invoked by
`quarantine start` itself, as opposed to `provisioners/`, which is. Today
just `new-app.sh`.

**`docs/`** — this file, plus `adding-an-app.md`, `client-install.md`,
`gitops-prod.md`, and `runners-and-sandboxing.md`.

**`.github/workflows/`** — `verify-secrets-encrypted.yml` (fails CI if any
`secrets.sops.yaml` anywhere in the repo is missing SOPS's `sops:` metadata
stanza, i.e. isn't actually encrypted) plus `lint-and-validate.yml`
(shellcheck on every shell script, `docker compose config` validation of
the assembled `environments/_template/compose.yaml` graph, on every PR).

**`README.md`** — the three-command quickstart.

## Secrets

See `.sops.yaml` and `environments/_template/secrets.example.yaml` for the
full model. In short: `secrets.example.yaml` is a plaintext list of
required keys, never encrypted and never deployed as-is — `quarantine
init` reads it only to know which keys to fill, then writes
`environments/<env>/secrets.sops.yaml` directly in already-encrypted form.
Plaintext must never exist at a deployable path, not even transiently.
Two backstops enforce this: the CI workflow above, and `.gitignore`
patterns rejecting any `environments/*/secrets*.yaml` variant that isn't
the `.sops.yaml`-suffixed, actually-encrypted file.

## Zitadel API (decision 5)

`provisioners/zitadel.sh` uses Zitadel's v2 resource APIs — Connect
protocol (`POST /<package>.<Service>/<Method>`, JSON body), confirmed
directly against `zitadel/zitadel`'s own `.proto` sources
(`zitadel.project.v2.ProjectService`, `zitadel.application.v2.
ApplicationService`) rather than the older v1 gRPC-gateway "management"
API. Authentication is a Personal Access Token (PAT), not a machine JSON
key: `infra/identity/zitadel/compose.yaml` bootstraps a dedicated
`quarantine-provisioner` machine user via `ZITADEL_FIRSTINSTANCE_ORG_
MACHINE_*` on first boot, writing its PAT to a volume the provisioner
reads exactly once and persists into `secrets.sops.yaml`. A PAT was chosen
over a machine key file because it needs no token-exchange step and
avoids the `urn:zitadel:iam:org:project:id:zitadel:aud` audience-scope
requirement that applies to regular OAuth2 access tokens — a Bearer PAT
works directly against every v1 and v2 endpoint.

Two things worth knowing if you're extending `zitadel.sh`:

- **Every API call goes over the internal `edge` Docker network**
  (`http://zitadel-api:8080/...`, via a throwaway `curlimages/curl`
  container), never through the public `https://auth.${DOMAIN}/api/...`
  route. The public route depends on DNS propagation and ACME (DNS-01)
  cert issuance, neither guaranteed to have completed the moment
  `zitadel-api` reports healthy; going in-network sidesteps both.
- **Every call needs an explicit `Host: auth.${DOMAIN}` header.** Zitadel
  resolves which instance (tenant) a request belongs to from the request's
  Host/origin matched against `ZITADEL_EXTERNALDOMAIN` — not from how the
  TCP connection was actually addressed. Omitting it fails with
  `{"code":5,"message":"... Instance not found"}` (verified empirically).

One project (`quarantine-apps`) holds one OIDC application per catalog app
needing `needs_oidc`; `client_id`/`client_secret` are captured and
persisted immediately (Zitadel only returns the secret once, at creation).
If a prior provisioning run created the Zitadel-side application but was
killed before persisting its credentials, the next run finds it by name
and calls `GenerateClientSecret` to mint fresh, usable credentials for the
*existing* application rather than creating a duplicate.

## Renamed: `komodo` profile → `gitops`

Two behavior changes were deliberately deferred out of the restructure
that produced the layout above, so that restructure could stay a pure
path move with its own clean verification, then done as a separate,
follow-up commit:

1. **Renamed the `komodo` compose profile to `gitops`**, everywhere it was
   referenced (compose fragments, Komodo's own resource TOML, this doc).
   The `komodo` service/container/folder names themselves are unaffected —
   only the profile string changed.
2. **Profile-gated `infra/observability/`** (previously always-on,
   unprofiled) behind a new `observability` profile.

Resolved once the CLI was built: `quarantine start` doesn't rely on a
`COMPOSE_PROFILES` environment-variable default at all — it passes
`--profile observability` explicitly on every invocation (unconditionally)
and `--profile gitops` explicitly whenever a given environment's
`manifest.yaml` sets `gitops: true` (see `cmd_start` in `bin/quarantine`).
The active service set is therefore always explicit and reproducible from
the manifest, with no implicit environment-variable state to keep in sync.

## Status

Built and live-tested end-to-end (`init` → `start` → idempotent re-`start`
→ `app add`/`app remove` reconciliation → `status` → `destroy`, including
real OIDC provisioning against a live Zitadel instance): `infra/*`,
`apps/third-party/uptime-kuma`, `catalog.yaml`, `environments/_template/`,
`lib/common.sh`, `bin/quarantine`, `provisioners/postgres.sh`,
`provisioners/zitadel.sh`, `install.sh`, `.gitignore`, `.sops.yaml`,
`scripts/new-app.sh`, all of `docs/`, and both CI workflows
(`verify-secrets-encrypted.yml`, `lint-and-validate.yml`). The `komodo` →
`gitops` profile rename and `observability` profile-gating are both done.

Immich and Stirling PDF were removed from the initial catalog (they were
meant as illustrative examples; re-add them via `scripts/new-app.sh` once
the platform itself is running and proven — see `docs/adding-an-app.md`).
`environments/dev/` and `environments/prod/` don't exist yet — they get
created the first time `quarantine init` runs for each.
