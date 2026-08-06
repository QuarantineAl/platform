# Client install: standing up a new environment on a fresh host

This is the walkthrough for taking a brand-new host — a new client server,
or a rebuild of an existing one — from bare Debian/Ubuntu to a running
quarantine environment: install the CLI, run `init`, run `start`, verify
it, and know what day-2 operations look like from here.

This doc is operational, not architectural. For *why* the repo is laid out
the way it is, see [`docs/architecture.md`](./architecture.md). For the CI
runner and PR-sandbox model, see `docs/runners-and-sandboxing.md`. For
adding a new third-party app to the catalog before you deploy it here, see
`docs/adding-an-app.md`.

## Prerequisites

Have these ready *before* you start — `quarantine init` will ask for most
of them, and getting them mid-run is a context switch you can avoid:

| Requirement | Why |
|---|---|
| A domain you control, delegated to Cloudflare DNS | Traefik's ACME client uses Cloudflare's DNS-01 challenge, not HTTP-01 — see [Step 3](#step-3-quarantine-start) for what that does and doesn't buy you. |
| A Cloudflare API token scoped to `Zone:DNS:Edit` for that zone | Passed to `quarantine init` via `--cf-token`, or typed at an interactive prompt. Used by Traefik to create the DNS-01 TXT records it needs to prove domain ownership to Let's Encrypt. Don't hand it a broader scope than `Zone:DNS:Edit` on the one zone. |
| A fresh Debian/Ubuntu host, x86_64 or arm64 | `install.sh` only supports `apt-get`-based distros. Anything else needs the dependencies installed by hand (see `install.sh`'s own comments for the exact list and versions) — not covered here. |
| Ports 80 and 443 free on that host | Traefik binds both directly. If something else is already listening (a previous nginx/apache install, another reverse proxy), stop and disable it first. |
| Root or sudo access on the host | `install.sh` must run as root. Keep running as root (or via `sudo`) for `quarantine init`/`start`/etc. too — see the note at the end of [Step 1](#step-1-install-system-dependencies). |

Nothing above needs a live A record yet. DNS-01 means the ACME certificate
can issue before the domain resolves anywhere — see [Step
3](#step-3-quarantine-start) for the detail. You do still need the domain
*delegated to Cloudflare's nameservers* (so Cloudflare can create the TXT
record the challenge needs), which is a one-time registrar-side change,
independent of any A record.

## Step 1: install system dependencies

`install.sh` is curl-able and installs everything else in this walkthrough
depends on: Docker + the compose v2 plugin, git, curl, age, sops, yq, and a
`flock` sanity check. Run it as root:

```bash
curl -fsSL <raw-url-to-install.sh> | sudo bash
```

What it does, in order:

1. `apt-get update` + installs `git curl age ca-certificates`.
2. Installs Docker via the official `get.docker.com` convenience script,
   *only if* `docker` isn't already present — safe to run on a host that
   already has Docker.
3. Installs `sops` and `yq` by downloading the exact pinned release binary
   for your architecture and verifying its SHA-256 against a hardcoded
   checksum before installing — never via `apt-get`. This matters for
   `yq` specifically: Debian/Ubuntu's `apt` package is
   `kislyuk/yq` (a Python wrapper with a different expression syntax);
   this codebase is written against `mikefarah/yq`, the Go rewrite. Getting
   the wrong one would make every `quarantine` command that shells out to
   `yq` fail or silently misbehave.
4. Confirms `flock` is present (it ships with `util-linux` on any standard
   Debian/Ubuntu host — this is just a sanity check, not an install step).
5. Clones the repo to `/opt/quarantine/repo` (or `git pull --ff-only`s it
   if that path already has a checkout — safe to re-run `install.sh` later
   as an update mechanism, same as `quarantine upgrade`).
6. Symlinks `bin/quarantine` from that checkout onto `/usr/local/bin/quarantine`.

Three environment variables override the defaults, useful for testing or
for a non-standard layout:

| Variable | Default | Overrides |
|---|---|---|
| `QUARANTINE_REPO_URL` | `https://github.com/QuarantineAl/platform.git` | Which repo gets cloned. Override only for a fork or private mirror — set it on the `sudo ... bash` side of the pipe (see below). |
| `QUARANTINE_INSTALL_DIR` | `/opt/quarantine/repo` | Where the repo is cloned. |
| `QUARANTINE_BIN_LINK` | `/usr/local/bin/quarantine` | Where the CLI gets symlinked onto `PATH`. |

```bash
curl -fsSL <raw-url-to-install.sh> | \
  sudo QUARANTINE_REPO_URL=https://github.com/your-fork/platform.git bash
```

The variable has to be attached to the `sudo ... bash` side of the pipe,
not exported before `curl` — `curl` never reads it, and `sudo` resets the
environment by default (it doesn't inherit whatever was exported in the
calling shell), so `install.sh`'s own `${QUARANTINE_REPO_URL:-...}`
expansion — which runs inside the `bash` process `sudo` execs — would
still see the default otherwise.

**Stay root (or use `sudo`) for every `quarantine` command from here on.**
`install.sh` creates `/opt/quarantine/repo` as root, and `quarantine init`
writes host config and the environment's age key under `/opt/quarantine/`
too (`/opt/quarantine/quarantine.yaml`, `/opt/quarantine/keys/`, both
0600). Nothing in `bin/quarantine` explicitly checks its own UID, but if
you switch to a non-root user partway through, you'll hit plain permission
errors against a root-owned `/opt/quarantine` tree rather than anything
more informative.

## Step 2: `quarantine init`

`quarantine init` is one-time setup per environment: preflight checks,
age-key restore-or-generate, environment creation from `_template`, initial
secrets generate-or-restore, writing `/opt/quarantine/quarantine.yaml`, and
a best-effort DNS check. It's safe to re-run — it never overwrites an
existing environment directory or an existing `secrets.sops.yaml`; a second
run against the same environment name verifies what's there instead.

Full usage:

```
quarantine init [--domain DOMAIN] [--env NAME] [--email EMAIL] [--cf-token TOKEN] [--age-key-file PATH]
```

`quarantine init --help` prints this same summary from the CLI itself.

### What "environment name" means here

An environment (`--env`) is a directory (`environments/<env>/`) holding one
manifest, one `compose.yaml`, one `secrets.sops.yaml`, and one age key —
in other words, one deployable unit with its own domain and its own set of
running apps. For a dedicated single-tenant host, `prod` (the default if
you just hit enter interactively) is a perfectly normal choice. If your
convention is one environment name per client instead, use that client's
slug — `--env acme-corp`, say. Either way the name must match
`^[a-z][a-z0-9-]*$` (lowercase letters, digits, hyphens, starting with a
letter); `quarantine init` rejects anything else immediately.

### Interactive flow

Run it bare and it prompts for anything you didn't pass as a flag:

```bash
quarantine init
```

```
Environment name [prod]: acme-corp
Domain (e.g. example.com): acme-corp.example.net
ACME/admin email: ops@yourorg.com
No age key found for 'acme-corp'. [g]enerate new or [r]estore from backup? [g]:
```

Hit enter on the last prompt (or type `g`) for a **brand-new environment** —
the normal path when the host is genuinely new and this environment name
has never existed before. It generates a new age key, then prompts for the
Cloudflare API token (typed input is hidden):

```
Cloudflare API token (Zone / DNS / Edit, scoped to this domain):
```

### The age key: back it up before anything else

This is the one step in this whole walkthrough where a mistake is
unrecoverable, so it gets its own section.

`quarantine init` handles the age key for an environment one of three ways:

- **A key already exists** at `/opt/quarantine/keys/age-<env>.txt` (default
  path; `QUARANTINE_KEYS_DIR` overrides the directory) — it's used as-is,
  no prompt.
- **Generate** (`g`, the default): `age-keygen` creates a brand-new
  keypair, private half written to that path at mode 600.
- **Restore** (`r`): you paste an existing private key at the prompt
  (Ctrl-D to finish), or — non-interactively — point `--age-key-file PATH`
  at a copy of it on disk. This is how you bring a *previously backed-up*
  environment's key onto a new or rebuilt host.

Whichever path you took, **the moment a key is generated (or restored),
back it up before you do anything else** — before typing the Cloudflare
token, before `quarantine start`, before anything. Copy
`/opt/quarantine/keys/age-<env>.txt` somewhere durable and access-controlled:
a password manager entry, an offline encrypted drive, whatever your org's
secrets-handling policy already covers credentials of this sensitivity.

Why this matters as much as it does: this key is the *only* way to decrypt
`environments/<env>/secrets.sops.yaml` — which holds every generated
credential for that environment (Postgres admin password, Zitadel
masterkey and admin password, the oauth2-proxy cookie secret, every app's
OIDC client secret, and the Cloudflare API token itself).
`secrets.sops.yaml` is safe to commit to git specifically *because*
it's encrypted — but that safety is entirely contingent on the age private
key living somewhere else, under your control. **There is no recovery
mechanism if it's lost — none exists, none is planned.** Losing it means
re-provisioning the environment from scratch: new age key, new generated
secrets, new OIDC clients, effectively a new environment under the old
name.

If you're restoring a previously-backed-up key onto a rebuilt host — the
scripted/CI path, or just non-interactive by preference — pass it directly:

```bash
quarantine init --env acme-corp --domain acme-corp.example.net \
  --email ops@yourorg.com --age-key-file /path/to/age-acme-corp.txt
```

Restore has its own verification: `quarantine init` decrypts the existing
`environments/<env>/secrets.sops.yaml` (if that environment already has one
committed to this repo) with the restored key and checks every required
key is present and not a leftover `CHANGEME` placeholder before it accepts
the key as correct and updates `.sops.yaml`'s recipient for that
environment. If the key doesn't decrypt at all, or the file is missing
required keys (e.g. a stale backup predating a schema change), `init` dies
with a specific error rather than silently continuing — no `--cf-token` is
needed on this path, since nothing is being generated.

### Non-interactive / CI flag set

Every prompt above has a corresponding flag, all required together when
stdin isn't a TTY (scripted install, CI, config management):

```bash
quarantine init \
  --domain acme-corp.example.net \
  --env acme-corp \
  --email ops@yourorg.com \
  --cf-token "$CF_API_TOKEN" \
  --age-key-file /path/to/age-acme-corp.txt   # omit for a brand-new environment
```

- `--domain`, `--env`, `--email` are always required non-interactively.
- `--cf-token` is required non-interactively *unless* an existing,
  already-complete `secrets.sops.yaml` is being restored (nothing needs
  generating in that case).
- `--age-key-file` is required non-interactively *only* when restoring an
  environment whose `secrets.sops.yaml` already exists and no age key is
  yet present on this host. Omit it for a brand-new environment — with no
  TTY and no `--age-key-file`, `init` just generates a fresh key with no
  prompt (the same default a TTY session gets by hitting enter on `[g]`).

### What `init` actually does to disk

- Creates `environments/<env>/` from `environments/_template/` — **only**
  if that directory doesn't already exist. Re-running `init` against an
  existing environment never overwrites it.
- Writes `environments/<env>/secrets.sops.yaml` (SOPS-encrypted, real
  generated credentials) — again, only if it doesn't already exist;
  otherwise verifies it as described above.
- Updates `.sops.yaml`'s recipient for this environment's path, but only
  after proving (via a successful decrypt, or a fresh generate) that the
  key being written is the one that actually works.
- Writes `/opt/quarantine/quarantine.yaml` (override the path via
  `QUARANTINE_CONFIG_FILE`), mode 600 — this is what every other
  `quarantine` command reads to know which repo checkout, environment,
  domain, and email to operate against.
- Runs a **best-effort, non-blocking** DNS check for `<domain>` and
  `auth.<domain>` against this host's public IP (auto-detected). A miss
  here only prints a warning — it never fails `init`. See [Step
  3](#step-3-quarantine-start) for what the warning does and doesn't mean.

If this is a genuinely new environment, `init` finishes by printing a
reminder to `git add`/`commit`/`push`
`environments/<env>/secrets.sops.yaml` (and `.sops.yaml`, if this is the
first environment of this name in the repo) — the CLI never commits or
pushes on its own.

## Step 3: `quarantine start`

```bash
quarantine start
```

`start` is an idempotent reconcile: it brings this environment's desired
state up from whatever state it's currently in, and is safe to re-run any
number of times (including immediately after itself, with no changes).

What comes up, in this order, every run:

1. **Traefik** — waits for it to report healthy before moving on.
2. **Postgres** (shared instance) — waits healthy, then runs
   `provisioners/postgres.sh` to ensure Zitadel's own role/database exist.
3. **Zitadel** (`zitadel-api` + `zitadel-login`) — waits for both to report
   healthy. In practice this is the slowest step on a first `start`:
   Zitadel is running its own first-boot migrations against a fresh
   Postgres role, and the health check can take a couple of minutes before
   it goes green. Subsequent `start` runs are fast — nothing to migrate.
   Once `zitadel-login` is healthy, `provisioners/zitadel.sh ensure-features`
   runs against the live `SetInstanceFeatures` API to force
   `loginV2.required=false` — this is re-applied on every `start`, not just
   first boot, because the equivalent env var
   (`ZITADEL_DEFAULTINSTANCE_FEATURES_LOGINV2_REQUIRED`) only takes effect at
   first-ever instance creation. See `infra/identity/zitadel/compose.yaml`
   for why this matters (a known upstream Login V2 bug in Zitadel's own
   Console).
4. **Observability** (SigNoz + otel-collector) — brought up unconditionally,
   always, regardless of catalog/manifest state. There's no explicit health
   wait after this step; give it a minute before expecting the SigNoz UI to
   respond.
5. **The CI runner pool**, if this environment's `compose.yaml` includes
   `infra/ci/github-runner/` — added by hand per environment, never via
   `_template/`. See `docs/runners-and-sandboxing.md`.
6. **The host's GHCR login** (`ensure_ghcr_login` in `lib/common.sh`) — logs
   the host's own Docker daemon into `ghcr.io` using
   `core.ghcr.pull_username`/`pull_token` from this environment's secrets,
   if set. This is only needed for ad hoc, non-CI image pulls (`quarantine
   start`/`app start` run directly on the host); CI's own pulls authenticate
   separately via the ephemeral `GITHUB_TOKEN`. A no-op if those secret keys
   are still unset.
7. **Every app in `manifest.yaml`** — for a fresh environment this list is
   empty (`apps: []` out of `_template`), so this step is a no-op until you
   run `quarantine app add`. Once apps exist, each one needing a database
   or OIDC client gets provisioned (`provisioners/postgres.sh` /
   `provisioners/zitadel.sh`) before all manifest apps are started together
   in one combined `up -d` call.
8. **Anything running that's no longer in the manifest** gets stopped (not
   removed, not volume-deleted) — this is the other half of "manifest is
   desired state": removing an app from the manifest and re-running `start`
   is how it actually stops.

### The DNS check warnings

If you saw a warning during `init` like:

```
[quarantine] WARN: DNS not configured for acme-corp.example.net — create an A record: acme-corp.example.net -> 203.0.113.10
```

this is expected on a genuinely new deployment and doesn't block anything.
Traefik's ACME client uses Cloudflare's **DNS-01** challenge, not HTTP-01 —
it proves domain ownership by creating a TXT record via the Cloudflare API
token you supplied, not by serving a file over HTTP on the domain itself.
That means **the TLS certificate can issue successfully before any public A
record exists or has propagated.** Don't mistake a clean `quarantine start`
and a valid cert for "traffic is reaching this host" — those are two
different things. You still need to create the real A record(s) (the
domain itself, plus `auth.<domain>` and any app subdomain you add) pointing
at this host's public IP for actual traffic to arrive. The IP `init`
printed in the warning is what to point them at.

## Step 4: verifying the install

```bash
quarantine status
```

This runs `docker compose ps` across every profile this environment could
have active — `observability` and every name in `catalog.yaml` — so it's
a full picture regardless of what's actually in the manifest.
Everything from Step 3 should show as running/healthy.

Then check the identity provider is actually reachable over TLS:

```
https://auth.<your-domain>
```

You should get a valid certificate (proof DNS-01 issuance worked) and
Zitadel's login UI. If you've added any catalog app already (see below),
check its subdomain too — e.g. `https://status.<your-domain>` for
Uptime Kuma.

## Day-2 operations

### Adding and removing apps

```bash
quarantine app add uptime-kuma --version 1.2.3
quarantine app remove uptime-kuma
```

`app add` validates the name exists in `catalog.yaml` first — see
`docs/adding-an-app.md` if it doesn't yet and you want to add it. Both
subcommands only mutate `environments/<env>/manifest.yaml` on disk; neither
starts, stops, or commits anything by itself. Run `quarantine start` after
either one to actually apply the change, and — since the CLI never commits
or pushes — `git add`/`commit`/`push` the manifest change yourself
afterward (both subcommands print this reminder), so the repo stays an
accurate record of what's actually running.

### Checking the version

```bash
quarantine version
```

Prints `git describe --tags --dirty --always` for the repo checkout on
disk — a bare commit SHA today (this repo has no tagged releases yet), a
real `vX.Y.Z`-style string once tagged releases start landing, and a
`-dirty` suffix if the checkout has uncommitted local changes (which
should never happen on a real deploy host).

### Upgrading

```bash
quarantine upgrade
```

Requires the repo to currently be on branch `main` — dies with a clear
error otherwise, rather than silently fast-forwarding whatever branch is
actually checked out. Then fetches and fast-forward-only merges
`origin/main`, and re-execs `quarantine start`. It first asserts the repo
path recorded in `/opt/quarantine/quarantine.yaml` and the CLI's own
on-disk location resolve to the same checkout — if they've diverged (a
hand-edited `quarantine.yaml`, a relocated checkout), it dies with a clear
error instead of pulling code it then never actually runs.

### Destroying

```bash
quarantine destroy
```

Requires typing the exact environment name to confirm, then `docker
compose down` across every profile — **not** `-v`. Volumes are explicitly
preserved. `quarantine start` afterward recreates containers against the
same Postgres data, Zitadel state, etc. Use this for "tear down containers,
keep everything else" (e.g. before a host migration where you'll bring the
same environment back up on new hardware) — not for actually decommissioning
an environment's data.

### Backups: what to actually back up

| What | Back it up? | Why |
|---|---|---|
| The age private key (`/opt/quarantine/keys/age-<env>.txt`) | **Yes — this is the one that matters.** Offline, access-controlled, immediately after generation. | The only way to decrypt this environment's secrets. No recovery mechanism exists if it's lost — see [Step 2](#the-age-key-back-it-up-before-anything-else). |
| `environments/<env>/secrets.sops.yaml` | Already safe — it's committed to git, encrypted. Nothing extra to do here. | SOPS ciphertext is meaningless without the age key above, by design. |
| `environments/<env>/manifest.yaml`, `compose.yaml` | Already safe — committed to git, plaintext by design (the CLI reads them without decrypting anything). | Not sensitive; desired-state config, not secrets. |
| Each app's own data volumes (Postgres data, Zitadel state, any app-specific volume) | Yes, if the app's data matters to you — this is genuinely outside what `quarantine` itself backs up. | `quarantine destroy` preserves volumes across a teardown/recreate, but that's not the same as an off-host backup surviving lost/corrupted disks. Back these up the way you'd back up any Docker volume — this repo doesn't prescribe a mechanism. |

Everything in the first column that isn't the age key is either already
safe in git or explicitly out of scope for this CLI. The age key is the
one piece of state that lives nowhere else and has no fallback — treat it
accordingly.
