# Adding an app to the catalog

`catalog.yaml` is the one place every catalog-managed app is declared —
`bin/quarantine` and `provisioners/*.sh` read it at runtime and hardcode
nothing app-specific. `quarantine app add <name>` refuses to touch a
manifest unless `<name>` already has an entry there (it dies with `'<name>'
is not in catalog.yaml — see docs/adding-an-app.md` if not — that message is
what points people here).

Adding a real app is two phases: `scripts/new-app.sh` scaffolds the
mechanical, always-the-same-shape parts; everything specific to the app you're
actually adding is a manual step afterward. Skipping a manual step doesn't
fail loudly at scaffold time — it fails later, confusingly, at `quarantine
start` or inside the app itself. This doc is the checklist that keeps that
from happening.

## 1. `catalog.yaml` field reference

| Field | Meaning |
|---|---|
| `name` | Matches the compose `profile` name and the `manifest.yaml` entry. Also the basis for the exported `<APP>_VERSION` var and any injected `DATABASE_URL_<APP>` / `OIDC_CLIENT_ID_<APP>` / etc. vars (name upper-cased, hyphens → underscores). |
| `kind` | `"core"` (always-on infra, not user-removable) or `"app"` (third-party/first-party, catalog-managed via `quarantine app add`/`remove`). **Not** the same axis as the `apps/<kind>/` directory split below — see the note at the end of this section. |
| `compose_path` | Path to the compose fragment, relative to repo root. |
| `subdomain` | The Traefik `Host()` label prefix; full host is `<subdomain>.${DOMAIN}`. |
| `needs_db` | If `true`, `provisioners/postgres.sh` creates a database + role named after `name` (hyphens → underscores) before the app starts. |
| `needs_oidc` | If `true`, `provisioners/zitadel.sh` creates a Zitadel project + OIDC client before the app starts, and the CLI injects `OIDC_CLIENT_ID_<APP>` / `OIDC_CLIENT_SECRET_<APP>`. |
| `oidc_redirect_uris` | Redirect URIs registered on the OIDC client. Only present when `needs_oidc` is true. |
| `notes` | Free-text caveats — surfaced by `quarantine app add` and read by whoever's adding the next app. |

The current (and, at the time of writing, only) entry, quoted verbatim from
`catalog.yaml`, is the worked example to copy from:

```yaml
  - name: uptime-kuma
    kind: app
    compose_path: apps/third-party/uptime-kuma/compose.yaml
    subdomain: status
    needs_db: false
    needs_oidc: true
    oidc_redirect_uris:
      - "https://status.${DOMAIN}/oauth2/callback"
    notes: >-
      Uptime Kuma itself has no native OIDC support — the OIDC client this
      entry provisions is consumed by an oauth2-proxy sidecar (not Uptime
      Kuma directly), which forward-auth-protects the admin UI while public
      status-page paths stay unauthenticated on the same host. Monitors run
      from inside this host only — an external uptime probe is a separate,
      out-of-scope concern (see docs/architecture.md).
```

Note the two unrelated meanings of "kind" in play: `catalog.yaml`'s `kind:
app` field (vs. `core`) is about lifecycle — whether `quarantine app
add`/`remove` manages it. The `<kind>` argument to `scripts/new-app.sh`
(`third-party` vs `first-party`) is about provenance — which `apps/<kind>/`
directory the compose fragment lives in. Every app scaffolded by
`scripts/new-app.sh` gets `kind: app` in `catalog.yaml` regardless of which
`apps/` subdirectory it lands in.

## 2. Scaffold with `scripts/new-app.sh`

```
Usage: scripts/new-app.sh <name> <kind> [--subdomain <sub>] [--image <ref>]

  <name>   catalog/profile name, e.g. "paperless" (lowercase, hyphens ok)
  <kind>   "third-party" or "first-party"

Options:
  --subdomain <sub>   Host prefix for Traefik routing (default: <name>)
  --image <ref>        Image reference to pre-fill (default: a CHANGEME
                        placeholder — third-party apps rarely have a
                        knowable ${<APP>_VERSION}-pinned tag at scaffold
                        time; first-party apps default to
                        ghcr.io/<org>/<name>)
```

Example:

```
scripts/new-app.sh paperless third-party --subdomain docs
```

This is idempotent in the safe direction only: it **refuses to overwrite**
an existing `apps/<kind>/<name>/` folder or an existing `catalog.yaml` entry
with that name. If you need to re-scaffold, remove both by hand first.

It produces two things:

- **`apps/<kind>/<name>/compose.yaml`** — joins the `edge` network, carries
  Traefik labels routing `<subdomain>.${DOMAIN}` to the service, a
  `CHANGEME` healthcheck placeholder, and an image pinned via
  `${<APP>_VERSION:-CHANGEME}`.
- **A new `catalog.yaml` entry** — `kind: app`, the right `compose_path` and
  `subdomain`, `needs_db: false`, `needs_oidc: false`, and a `notes:
  "CHANGEME: scaffolded by scripts/new-app.sh, not yet reviewed."` field.

Neither is meant to run as-is. Every `CHANGEME` in both files is a marker for
step 3 below.

## 3. Manual follow-up (the part `scripts/new-app.sh` can't do for you)

### 3.1. Fill in the scaffolded `compose.yaml`

Open `apps/<kind>/<name>/compose.yaml` and replace every `CHANGEME`:

- The real image reference and version (the `${<APP>_VERSION:-CHANGEME}`
  variable is fine to keep — it's how `quarantine app add --version`
  reaches the container — just point `image:` at the real registry path).
- A real `healthcheck.test` command — `["CMD", "true"]` always reports
  healthy and defeats `wait_healthy`'s purpose during `quarantine start`.

### 3.2. Flip `needs_db` / `needs_oidc` in `catalog.yaml`

Leave `false` alone if the app genuinely needs neither. Otherwise:

- **`needs_db: true`** — `provisioners/postgres.sh` will automatically
  create a role + database named after `<name>` the first time `quarantine
  start` reconciles this app. No catalog field beyond the flag itself is
  required.
- **`needs_oidc: true`** — add an `oidc_redirect_uris` list (see the
  uptime-kuma entry above for the shape). `provisioners/zitadel.sh` will
  automatically create the Zitadel project (shared, `quarantine-apps`) and
  one OIDC application for this entry.

Both provisioners are called automatically by `quarantine start` for every
manifest app whose catalog record sets the corresponding flag — you never
invoke `provisioners/*.sh` directly in normal use.

### 3.3. Wire up secrets, if the app needs any

Whether this step applies — and what it looks like — depends on *which*
kind of secret the app needs:

- **The app's Postgres password (`needs_db: true`)** — nothing to wire.
  `provisioners/postgres.sh` reads `.apps["<name>"].db_password` out of
  `secrets.sops.yaml` and, if it's missing or still a `CHANGEME*`
  placeholder, generates one with `gen_password` and persists it via
  `secrets_set` — the same lazy-generate-on-first-run behavior already used
  for Zitadel's own database password. It's worth adding a
  `db_password: "CHANGEME-generated-on-first-start"` line under
  `apps.<name>:` in `environments/_template/secrets.example.yaml` anyway, purely
  so the key is discoverable/documented — but it does **not** need to go in
  `bin/quarantine`'s `REQUIRED_SECRET_KEYS` array, and `quarantine init`
  never sees or generates it.
- **The app's OIDC client id/secret (`needs_oidc: true`)** — same story.
  `provisioners/zitadel.sh` persists `.apps["<name>"].oidc_client_id` /
  `.oidc_client_secret` into `secrets.sops.yaml` the first time it
  provisions the app (Zitadel only returns the client secret once, at
  creation). Add matching `CHANGEME-captured-from-zitadel-at-provision-time`
  placeholder lines to `secrets.example.yaml` (mirroring the uptime-kuma
  entry) for documentation, but again these are **not** `REQUIRED_SECRET_KEYS`
  members. What you *do* need to add by hand is the plumbing that gets these
  two values out of the decrypted secrets file and into the generated
  `.env` — in `generate_env_file()` in `bin/quarantine`, follow the
  `uptime_kuma_oidc_id`/`uptime_kuma_oidc_secret` pattern exactly: read both
  with `secrets_get` (not `req_secret` — they're legitimately empty until
  the provisioner has run once) and add
  `OIDC_CLIENT_ID_<APP>`/`OIDC_CLIENT_SECRET_<APP>` `printf` lines so the
  app's own `compose.yaml` can consume them.
- **Any other secret the app needs that has nothing to do with Postgres or
  Zitadel** (its own admin password, an API token, an encryption key it
  generates nowhere else) — there is no provisioner for this, so it has to
  be generated up front, at `quarantine init` time, the same way
  `core.oauth2_proxy.cookie_secret` and the `core.komodo.*` keys are:
  1. Add the key under `apps:` in
     `environments/_template/secrets.example.yaml` (placeholder value:
     `"CHANGEME-generated-at-init"`).
  2. Add the same yq path to the `REQUIRED_SECRET_KEYS` array in
     `bin/quarantine` — this is what makes `generate_secrets` fill it with
     `gen_password` at `quarantine init` and what makes
     `verify_secrets_complete` reject a restored `secrets.sops.yaml` that's
     missing it.
  3. Add a `req_secret` call for it inside `generate_env_file()`, and a
     `printf` line writing the resulting env var into the generated `.env`
     — following the existing `komodo_*`/`oauth2_cookie_secret` calls right
     above it in that function.

If the app needs none of the above (no DB, no OIDC, no bespoke secret), skip
this step entirely — that's exactly Uptime Kuma's `needs_db: false` case,
minus the OIDC half it does need.

### 3.4. Add the app to the compose include graph

`environments/_template/compose.yaml`'s `apps/third-party` (or
`first-party`) section is a plain list of `include:` paths, gated at
runtime by Compose profiles, not by which paths are listed — so a missing
include line means the app's services never exist in the assembled
config at all, regardless of `manifest.yaml`. Add:

```yaml
  - path: ../../apps/<kind>/<name>/compose.yaml
```

**Do this in two places, not one.** `environments/_template/compose.yaml` is
copied verbatim into `environments/<env>/` only once, at `quarantine init`
time — it is not a live symlink back to `_template`, and nothing re-syncs it
afterward. So if any environment already exists on this host (none do yet in
this repo, but this matters the moment one does), add the identical include
line to that environment's own `environments/<env>/compose.yaml` copy too,
or the app will be in `catalog.yaml` and possibly in that environment's
manifest, yet never actually start.

## 4. Test it

```
quarantine app add <name>          # [--version <v>] optional
quarantine start
quarantine status
```

- `quarantine app add` validates `<name>` against `catalog.yaml` and adds it
  to `environments/<env>/manifest.yaml`. It — like `app remove` — never
  commits or pushes; it prints a reminder that you're responsible for `git
  add`/`commit`/`push`ing the manifest for GitOps sync.
- `quarantine start` is an idempotent reconcile: it brings up core infra
  (unconditionally), runs `provisioners/postgres.sh`/`provisioners/zitadel.sh`
  for this app if its `needs_db`/`needs_oidc` flags are set, then starts it
  via `--profile <name> up -d`.
- `quarantine status` runs `docker compose ps` across every profile,
  including this one — confirm the new service shows up and is healthy.

For logs, the scaffolded `container_name: quarantine-<name>` convention
means a plain

```
docker logs -f quarantine-<name>
```

works without needing to reconstruct the full `docker compose
--env-file ... -f environments/<env>/compose.yaml` invocation `qcompose()`
uses internally. If the app needed `needs_oidc`/`needs_db` provisioning and
something looks wrong, re-run `quarantine start` with `QUARANTINE_DEBUG=1`
first — `provisioners/postgres.sh` in particular withholds its own SQL
output (which can include a plaintext password) unless that's set.

## 5. Immich and Stirling PDF

`catalog.yaml` shipped Immich and Stirling PDF early on as illustrative
examples of what a real third-party app entry looks like, then removed
them — deliberately, not as an oversight — until the platform itself is
running and proven on real infrastructure. Uptime Kuma is the only app in
the catalog today.

If and when either gets re-added, this is exactly the walkthrough for doing
it: `scripts/new-app.sh <name> third-party`, then sections 3 and 4 above.
Neither is a committed item on any roadmap here — just an example of the
kind of app this process is meant for.
