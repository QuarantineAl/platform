# GitOps mode via Komodo

This doc covers when and how to run a quarantine environment in GitOps
mode, what Komodo's own resource files need to point at before that's
useful, the commit/push handover GitOps mode depends on (and where that
handover is currently incomplete), and the operating model this project
recommends for prod. It assumes you've read
[architecture.md](./architecture.md) for the repo layout and
[runners-and-sandboxing.md](./runners-and-sandboxing.md) for the
prod-is-pull-only-via-Komodo model — this doc doesn't re-explain either,
only the GitOps-specific mechanics both already assume.

## CLI-managed vs. GitOps-managed

Every environment is reconciled one of two ways, never both at once:

| | CLI-managed | GitOps-managed |
|---|---|---|
| Who mutates state | an operator, running `quarantine app add/remove` and `quarantine start` directly against the host | Komodo, pulling `environments/<env>/` from this repo and deploying what it finds |
| Where commands run | on the target host itself (or over SSH to it) | nowhere host-specific — an operator edits the repo (locally or on the host) and pushes; Komodo does the rest |
| What applies changes | `bin/quarantine`'s own reconcile logic (`cmd_start` / `reconcile_apps`): provisions DB roles and OIDC clients, starts/stops profiles, stops removed catalog apps | Komodo's Stack executor: a plain `docker compose --profile ... up -d` against the pulled `compose.yaml`, per that environment's `[[stack]]` block in `stacks.toml` |
| Recommended for | dev | prod (see [Recommended topology](#recommended-topology)) |

**Ownership rule (decision 7): a stack is managed by exactly one of these
two modes at a time.** Once an environment's `manifest.yaml` sets
`gitops: true` and a matching `[[stack]]` block in
`infra/deploy/komodo/resources/stacks.toml` targets it, stop running
`quarantine start` (or `app add`/`app remove` followed by *not* committing)
against that host directly — Komodo now owns reconciliation for it.

This isn't just a policy preference, it's a real race:
`acquire_lock` in `lib/common.sh` takes an exclusive `flock` over
`.quarantine-locks/<env>.lock` before any mutating `quarantine` command
runs, but that lock only guards concurrent *`quarantine` CLI* invocations.
Komodo's Periphery agent never calls `bin/quarantine` — it runs
`docker compose` directly against its own independent git checkout of the
repo (mounted at `/etc/komodo`, per
`infra/deploy/komodo/compose.yaml`'s `PERIPHERY_ROOT_DIRECTORY`). Nothing
stops a manually-run `quarantine start` from racing a Komodo-triggered
deploy on the same host, on the same containers, at the same time. The
ownership rule is what actually prevents that — not the lock.

## Enabling GitOps mode for an environment

There is no CLI flag for this. To turn it on for, say, `prod`:

1. Hand-edit `environments/prod/manifest.yaml` and add a top-level key:

   ```yaml
   gitops: true
   ```

2. Run `quarantine start` once, from the host, the normal way. `cmd_start`
   checks that key and — only when it's `true` — brings up the `gitops`
   compose profile: `komodo-core` and `komodo-periphery`
   (`infra/deploy/komodo/compose.yaml`). Everything else `quarantine start`
   always does (Traefik, Postgres, Zitadel, observability, manifest app
   reconciliation) happens exactly as it would without GitOps mode.

3. Komodo's UI comes up at `https://komodo.${DOMAIN}` (`KOMODO_HOST` in the
   compose fragment), logged in with `KOMODO_INIT_ADMIN_USERNAME` /
   `KOMODO_INIT_ADMIN_PASSWORD` — sourced from that environment's
   `secrets.sops.yaml` (`core.komodo.admin_password`, username defaults to
   `admin`). The bundled Periphery agent self-registers as a Server named
   `primary` on first connect (`KOMODO_FIRST_SERVER_NAME`) — this is why
   `servers.toml` doesn't declare it explicitly (see below).

**Turning it back off is not symmetric.** Setting `gitops: false` and
re-running `quarantine start` simply skips the `up -d` for that profile —
`cmd_start` has no corresponding "stop" path for it, unlike catalog apps
(which `reconcile_apps` explicitly stops when removed from the manifest).
If you need to actually tear Komodo down, stop it by exact service name,
not a bare `--profile gitops stop` — the same pitfall documented inline
next to `reconcile_apps` in `bin/quarantine` applies here too: a profile
`stop` with no service arguments also stops every *unprofiled* always-on
service (Traefik, Postgres, Zitadel), not just that profile's own
containers.

## Komodo's own resource definitions

Komodo's Server and Stack definitions are committed as TOML
(`infra/deploy/komodo/resources/servers.toml` and `stacks.toml`, per
decision 7) so Komodo's own config is git-tracked the same way an
environment's `compose.yaml`/`manifest.yaml` are. Both files ship with
placeholder/example content matching this project's conventions, not real
infrastructure — they need to be filled in before GitOps mode does
anything useful.

**`servers.toml`** — empty of `[[server]]` blocks by default, on purpose:
the bundled Periphery agent self-registers as `primary` the first time
`quarantine start` brings the `gitops` profile up, so declaring `primary`
again here would conflict with that auto-registration. Add a `[[server]]`
block only for an **additional** managed host beyond the one Komodo itself
runs on — one Periphery per additional host (the file's own comment shows
the shape: `name`, `description`, `tags`, and `[server.config].address`
pointing at that host's own Periphery listener). Until you actually have a
second host, leave this file's `[[server]]` section empty.

**`stacks.toml`** needs, before it points at anything real:

- **`your-org/quarantine` replaced everywhere it appears** — in
  `[[resource_sync]]`'s `git_account`/`repo` and in every `[[stack]]`
  block's `git_account`/`repo`. This repo has no remote configured yet;
  there's nothing to point at until one exists. Do this as part of
  standing up the first real remote, not before.
- **`run_directory` set to the real environment path** it should watch —
  the shipped example (`environments/prod`) already matches this repo's
  conventions, so for `prod` no change is needed; a second GitOps
  environment (e.g. a client's own) needs its own `[[stack]]` block with
  `run_directory` pointed at *its* `environments/<name>/`.
- **`server` matching a real, registered Server name** — `"primary"` if
  the stack targets the host Komodo itself runs on; the name you gave a
  `[[server]]` block above if it targets a different, additional host.
- **`webhook_enabled = true` wired up on the git host's side** —
  `poll_for_updates = true` works with zero further setup (Komodo polls),
  but push-triggered deploys need the webhook registered against your git
  host (e.g. a GitHub webhook) using `KOMODO_WEBHOOK_SECRET` from
  `secrets.sops.yaml`. Nothing in this repo does that registration for
  you; it's a manual, one-time step in Komodo's UI plus your git host's
  settings once a real remote exists.

**`extra_args` is currently hand-maintained, not auto-regenerated.** The
comment above the `prod` stack says it's "populated by `quarantine start`
... at the time GitOps mode is enabled" — that automation doesn't exist
yet. As of this writing, `bin/quarantine` never writes to
`stacks.toml`. In practice this means: every profile that needs to be
active for an environment — `gitops` itself, plus one `--profile
<app-name>` per app in that environment's `manifest.yaml` — has to be
listed in `extra_args` by hand, and kept in sync by hand every time
`quarantine app add`/`app remove` changes that manifest. Forgetting to
update it means Komodo's deploy won't start (or won't stop) an app's
containers even though the manifest says it should.

## The commit/push handover — and where it's currently incomplete

`quarantine init`, `app add`, and `app remove` only ever write local
files. None of them run `git add`/`commit`/`push` — each prints a reminder
saying exactly that:

```
remember to git add/commit/push environments/<env>/manifest.yaml for GitOps sync
remember to git add/commit/push environments/<env>/secrets.sops.yaml (and .sops.yaml if this is the first environment of its name) for GitOps sync
```

GitOps mode only ever sees a change once it's actually committed and
pushed to the branch Komodo's stack polls (`branch = "main"` in
`stacks.toml`). The workflow this implies for a GitOps-managed
environment:

1. Edit locally — `quarantine app add <name> --version v` / `app remove
   <name>`, or a direct hand-edit of `manifest.yaml` (both are supported;
   `quarantine start` is what reconciles either).
2. Review the diff (`git diff environments/prod/manifest.yaml`, or
   `environments/prod/secrets.sops.yaml` if a secret changed — SOPS
   ciphertext diffs safely, but check it's actually the file you meant to
   touch).
3. `git commit` and `git push` to the branch Komodo watches.
4. Komodo picks it up on its next poll (or webhook, once wired) and runs
   `docker compose ... up -d` with that stack's `extra_args` against the
   pulled `compose.yaml`.
5. Verify via Komodo's own UI (`https://komodo.${DOMAIN}`), or with
   `quarantine status` if you still have direct host access — that command
   only reads local `docker compose ps` state, so it will reflect Komodo's
   deploy once it lands, not a moment before.

**Two gaps in this handover worth knowing about, not glossing over:**

- **Provisioning doesn't happen on Komodo's side at all.**
  `provisioners/postgres.sh` and `provisioners/zitadel.sh` — which create
  an app's database role or Zitadel OIDC client — are only ever invoked
  from `reconcile_apps`, inside `quarantine start`. Komodo's deploy is a
  plain `docker compose up -d`; it never calls either provisioner. Adding
  a `needs_db`/`needs_oidc` app to a GitOps-managed environment and
  pushing the manifest change gets that app's *container* started by
  Komodo, but its database or OIDC client won't exist until something runs
  `quarantine start` against that host with access to its decrypted
  secrets — today, that still means a CLI run against the prod host at
  least once per new app, which is in tension with "prod is never
  CLI-mutated directly." There's no workaround for this beyond being aware
  of it; it isn't automated yet.
- **The secrets handover described in the compose comments isn't wired up
  either.** `infra/deploy/komodo/compose.yaml` and `stacks.toml` both
  describe an intended design where `quarantine start` registers decrypted
  secrets as Komodo Variables via its API the first time GitOps mode is
  enabled, referenced from each stack's config as `[[VARIABLE_NAME]]`
  placeholders — so Komodo's independent git checkout never needs a
  decrypted `.env`. `bin/quarantine` has no code that calls Komodo's API
  today, and the committed `stacks.toml` has no `environment` block using
  `[[VAR]]` placeholders — instead it sets `env_file_path = ".env"`, a
  literal file that `generate_env_file` only ever writes on the
  CLI-managed host (`environments/<env>/.env` is gitignored on purpose —
  see `.gitignore`'s own comment on why). Komodo's own clone of this repo
  won't have that file. Until the Variables-registration API call is
  actually implemented, a GitOps-managed environment's Komodo stack has no
  working, non-manual way to get real secret values into its
  `docker compose up`. Treat this as an open item, not a solved handover —
  don't assume pushing a manifest change is enough to get a fully-working
  deploy out of Komodo alone yet.

## Recommended topology

| | dev | prod |
|---|---|---|
| Mode | CLI-managed (fast iteration) or GitOps — either is fine | **GitOps-only.** Never CLI-mutated directly (`quarantine start`/`app add`/`app remove`/`upgrade`/`destroy` are all direct-host mutations — none of them belong in normal prod operation once Komodo owns it) |
| Host | its own host/VM | its own host/VM — never the same one as dev |
| Age key | `/opt/quarantine/keys/age-dev.txt` | `/opt/quarantine/keys/age-prod.txt` — **never the same key, never shared** (decision 6: one age key per environment, enforced by `.sops.yaml` path; dev and prod never share a Docker daemon, an edge network, or a Traefik instance either — see `runners-and-sandboxing.md`) |
| Untrusted code | never — same rule as prod, per `runners-and-sandboxing.md`'s runner model | never |

A couple of things that follow directly from "GitOps-only" for prod, easy
to overlook:

- `quarantine destroy`'s profile list is unconditional
  (`--profile observability --profile gitops` plus every catalog app,
  regardless of what's actually enabled) — running it against a
  GitOps-managed host tears down Komodo itself, not just the apps. Volumes
  are preserved, but this is not a command to run against prod outside a
  deliberate, planned decommission.
- `quarantine upgrade` (`git pull --ff-only` then re-exec `start`) is also
  a direct-host mutation. On a GitOps-managed prod, upgrading the CLI
  itself is rarely the point — reconciliation there is Komodo's job — so
  there's normally no reason to run it against prod at all.

## What this doc does not cover

The Komodo Variables-registration API call and the `stacks.toml`
`extra_args` auto-regeneration described above as not-yet-built — that's
future work, tracked implicitly by this doc until it exists, not
specified here. Multi-host Komodo topologies beyond "one additional
managed host" (the `servers.toml` comment anticipates one Periphery per
additional host; nothing beyond that shape has been designed). Rolling
back a bad GitOps-deployed change — Komodo's own deploy history/rollback
UI is Komodo's feature to use, not something this repo adds a wrapper
around.
