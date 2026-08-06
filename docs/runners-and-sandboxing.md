# CI runners and sandboxing

This document describes the agreed CI/runner model. `infra/ci/
github-runner/` is built and live on both dev and prod (see
[Recorded decision: prod gets its own runner too](#recorded-decision-prod-gets-its-own-runner-too)
below for why prod's runner exists at all — this doc originally specified
GitOps-only, Komodo-managed prod deploys, which turned out not to be worth
the operational cost).

## The model

- **GitHub-hosted runners** for anything touching untrusted code — in
  particular, fork PRs on public repos. Untrusted code never runs on
  infrastructure this org controls.
- **One shared pool of ephemeral self-hosted runners per environment** for
  trusted CI across *all* first-party apps — never one runner per app.
  Every first-party app's workflows target that environment's pool by
  label:

  ```yaml
  runs-on: [self-hosted, quarantine-dev]   # or quarantine-prod
  ```

  A shared pool, not per-app runners, keeps the number of things with
  Docker-socket access on a given host fixed regardless of how many
  first-party apps exist. dev's and prod's pools are entirely separate
  runners on entirely separate hosts — no runner ever has access to both
  environments' Docker sockets or age keys.

- **Implementation home**: the runner pool's compose fragment lives at
  `infra/ci/github-runner/` in *this* repo, included by hand in **both**
  `environments/dev/compose.yaml` and `environments/prod/compose.yaml`
  (never the shared `_template/`, since not every environment — e.g. a
  client install — necessarily wants one). Each environment sets its own
  `RUNNER_LABELS` (`quarantine-dev` / `quarantine-prod`). Registration
  secrets (the runner PAT) live in that environment's own
  `secrets.sops.yaml`, encrypted with that environment's own age key —
  dev's runner secret is never readable from prod's checkout or vice
  versa.

- **Ownership split** — four distinct concerns, four distinct owners:
  | Concern | Owner |
  |---|---|
  | Runner compute (the container running the agent) | this repo, `infra/ci/`, one instance per environment |
  | Runner registration/permissions | a GitHub org runner group, restricted to first-party repos, public-repo access off, fork-PR approval required |
  | Reusable workflow definitions | the org's `.github` repo |
  | Thin workflow callers | each app repo, calling the reusable workflows above |

  There is deliberately **no separate CI/CD repo**. Deployment logic is
  the same self-hosted-runner-driven reusable workflows for both
  environments — a caller workflow parameterizes `environment: dev` or
  `environment: prod`, which the reusable workflow uses to pick the
  matching runner label and target the app's own service(s) only (never
  the shared core infra — see the warning below).

**⚠️ A runner with access to the host's Docker socket is effectively root
on that host.** Each environment's runner is trusted with root-equivalent
access to *that environment's* host only — never the other environment's
age key, Docker daemon, or Traefik instance (decision 6: one age key per
environment, enforced by `.sops.yaml` path). Untrusted code (any fork PR
on a public repo) stays on GitHub-hosted runners in both environments,
full stop, regardless of how convenient a self-hosted runner might seem
for a one-off case. Every deploy workflow scopes its `docker compose up`
to the app's own service(s) — never a bare `quarantine start`/`--profile
gitops`-style invocation that could recreate the runner's own container
mid-job (confirmed empirically to kill the job doing the recreating; see
`QUARANTINE_SKIP_RUNNER` in `bin/quarantine`).

## Per-PR sandboxes

Built and live for dev; prod support follows the same design (see
[Recorded decision](#recorded-decision-prod-gets-its-own-runner-too)).
`pr-<n>-<app>` Compose project names on the target host are already the
isolation unit — many PR sandboxes can run side by side on the same host
with no extra infrastructure, since a distinct project name namespaces
containers/networks/volumes on its own. Which host a given PR's sandbox
lands on is decided by the PR's *base* branch, not by anything in the PR
itself: a PR opened against `develop` gets a dev sandbox, a PR opened
against `main` gets a prod sandbox, and a PR against any other base
branch gets no sandbox and triggers no runner at all.

Two things this needed a real decision on, resolved here:

**Shared core infra, not a separate stack per PR.** A PR sandbox gets its
own database+role and its own Zitadel OIDC client — via the *same*
`postgres.sh` / `zitadel.sh` provisioners that already exist, just called
with `pr-<n>-<app>` as the `<name>` argument, exactly like a real catalog
app. No provisioner changes needed to create these. Rejected: a fully
separate Postgres+Zitadel per PR — spinning up a whole second Zitadel
(bootstrap, admin-user creation, PAT capture) is genuinely slow, and
multiplies badly the moment more than one PR is open at once. Postgres and
Zitadel are exactly the infra this platform already designed to be safely
multi-tenant (the same reasoning behind "one DB per consumer" generally);
reusing that design for PRs is the same call, not a new one.

This does surface a real, currently-missing capability: the provisioners
only *create/heal* today, they never tear down. Sharing core infra means
`postgres.sh` and `zitadel.sh` need a reap mode — `DROP DATABASE` /
`DROP ROLE` and `DeleteApplication` respectively — triggered by
`on: pull_request: types: [closed]`, or every PR ever opened leaves a
permanent DB, role, and OIDC app behind. This is new provisioner work, not
just a new caller of existing code.

One edge case worth naming, not solving now: a PR that changes the
provisioners themselves (`bin/quarantine`, `postgres.sh`, `zitadel.sh`) is
testing the thing that manages shared infra — the one case where isolation
might matter more than convenience. Not designed for; worth remembering if
it comes up.

**Browsable previews, made cheap by one structural choice.** PR sandboxes
get a real hostname rather than existing only for automated tests hit over
the internal compose network. This is affordable in both environments, for
the same underlying reason via two different shapes:

- **dev**: `DOMAIN` is one level below the root (`dev.quarantine.al`), so
  the wildcard-cert mechanism already in `infra/edge/traefik/`
  (`main=${DOMAIN}` + `sans=*.${DOMAIN}`) already covers a PR hostname one
  level below *that* — `pr-<n>-<app>.dev.quarantine.al`.
- **prod**: `DOMAIN` *is* the bare root (`quarantine.al`), so its own
  wildcard (`sans=*.quarantine.al`) already covers a PR hostname one level
  below the root directly — `pr-<n>-<app>.quarantine.al` — with no
  separate case needed.

Either way: **zero additional cert or DNS work per PR** — no per-PR
Cloudflare API calls, no per-PR ACME requests. The homelab Traefik
instance in front of both VMs already disambiguates the two wildcards via
`HostSNIRegexp` + explicit router `priority` (prod's broader regex,
`^(quarantine\.al|.+\.quarantine\.al)$`, needs a lower priority than dev's
narrower one so a `*.dev.quarantine.al` request isn't captured by prod's
router first).

Routing itself needs no new mechanism: Traefik already does dynamic
label-based discovery for every service in this platform. A PR sandbox's
compose invocation just needs its own Traefik labels with a templated
`Host()` rule (`pr-${PR_NUMBER}-${APP_NAME}.${DOMAIN}`, where `DOMAIN` is
whichever environment's sandbox this is) — same mechanism every other
service already uses, just parameterized per PR.

A first-party app with no reviewer-facing UI (headless/API-only) can opt
out of the preview labels and run its CI against the sandbox over the
internal compose network only — an escape hatch, not the default.

## Recorded decision: prod gets its own runner too

This doc originally specified prod as **GitOps-only, pull-based via
Komodo** — no runner, self-hosted or GitHub-hosted, would ever deploy to
it. That was implemented (Komodo Core + Periphery + a dedicated MongoDB,
a Resource Sync watching this repo's `stacks.toml`) and run live against
prod. It was dropped in favor of giving prod its own self-hosted runner
pool, identical in shape to dev's, for reasons worth recording rather than
silently overwriting:

- **A real outage.** Deploying via Komodo's UI recreated the entire
  `gitops`-profiled service set — including Komodo's own Periphery agent,
  the process executing that very deploy. Periphery killed itself
  mid-deploy, leaving Traefik/Postgres/Zitadel/Mongo/Komodo-core all stuck
  in "Created" (never started), taking prod fully down until a manual
  `docker compose up -d` from the host recovered it. This is the same
  self-recreation hazard `QUARANTINE_SKIP_RUNNER` exists to prevent for the
  CI runner — Komodo's own design had no equivalent guard.
- **Mechanical friction disproportionate to the benefit.** Multiple
  Komodo-specific bugs surfaced getting it working (git-account identity
  semantics, `extra_args` vs `COMPOSE_PROFILES` for activating a compose
  profile, a Resource Sync silently resetting hand-configured Stack fields
  not declared in the synced TOML) — none fundamental, but all real
  operational cost.
- **The security benefit was smaller than it first looked.** The original
  rationale (§ above, "a runner with Docker-socket access is effectively
  root") is real, but scoping deploy workflows to touch only an app's own
  service(s) — which this org's reusable workflows already do — closes
  most of the same gap a pull-only model would. What's left is a
  comparison between "a scoped, root-equivalent CI runner" and
  "a root-equivalent GitOps agent with its own self-recreation hazard,"
  not "root-equivalent" vs. "no risk at all." Once framed that way, and
  absent a compliance requirement forcing pull-only deploys, prod's own
  runner (same isolation as dev's: separate host, separate age key, never
  a shared Docker daemon) was judged the better tradeoff.

Cleanup from this reversal: `infra/deploy/komodo/`, `infra/data/mongo/`,
and `docs/gitops-prod.md` were removed; `environments/prod/manifest.yaml`'s
`gitops: true` was reverted. The live Komodo/Mongo containers and volumes
on the prod host were decommissioned as part of the same change.

## What this doc does not cover

The reap-mode additions to `postgres.sh`/`zitadel.sh` described above
(tearing down a closed PR's database role and OIDC client) — not yet
built for either environment.

## Known issue: intermittent dispatch failures, unexplained (2026-08)

Observed on the `dev` runner, root cause not found:

- Push events to `lazaretto`'s `develop` branch sometimes create no workflow
  run object at all (`gh run list`/`/status` show nothing — not even a
  queued run), for multiple consecutive pushes over a couple of hours.
  Ruled out: workflow-file syntax, repo Actions enablement, workflow
  `state`, classic webhooks (a different, irrelevant mechanism). Never
  reached a root cause — would need `admin:org` GitHub access
  (org-level runner-group/policy inspection) that wasn't available at the
  time.
- Separately, the compose-managed dev runner container
  (`quarantine-dev-runner-1`) disappeared from GitHub's own org Runners UI
  (showed "Offline", then vanished entirely on refresh) while its local
  process stayed healthy, correctly configured
  (`RUNNER_SCOPE=org`/`ORG_NAME`/`LABELS`), and logged no errors. A
  `docker restart` produced a clean deregister/re-register cycle but did not
  restore its UI visibility. A second, disposable runner registered with a
  fresh one-time token came up and appeared normally, and was left in place
  as the de facto `quarantine-dev` runner.

If this recurs: check githubstatus.com first (no evidence either way that
this was GitHub-side), and note both container names/labels no longer match
1:1 with the org's runner list — reconcile that before assuming either
container is authoritative.
