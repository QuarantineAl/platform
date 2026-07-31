# CI runners and sandboxing

This document describes the agreed CI/runner model. **Nothing here is
implemented yet** — no `infra/ci/` folder exists, no runner is registered,
no workflow template has been written. This is the design every future
implementation of it must match, written down now so nothing built in the
meantime accidentally conflicts with it.

## The model

- **GitHub-hosted runners** for anything touching untrusted code — in
  particular, fork PRs on public repos. Untrusted code never runs on
  infrastructure this org controls.
- **One org-level shared pool of ephemeral self-hosted runners** for
  trusted CI across *all* first-party apps — never one runner per app.
  Every first-party app's workflows target the same pool by label:

  ```yaml
  runs-on: [self-hosted, quarantine-dev]
  ```

  A shared pool, not per-app runners, keeps the number of things with
  Docker-socket access on the dev host fixed regardless of how many
  first-party apps exist.

- **Implementation home**: the runner pool's future compose fragment
  lives at `infra/ci/github-runner/` in *this* repo, included **only** by
  `environments/dev/compose.yaml`. The prod include graph must never
  reference it — there is no path by which a runner definition reaches a
  prod environment's assembled compose. Registration secrets (the runner
  registration token, etc.) will live in the dev environment's
  `secrets.sops.yaml`, encrypted with the dev age key like everything else
  in that file.

- **Ownership split** — four distinct concerns, four distinct owners:
  | Concern | Owner |
  |---|---|
  | Runner compute (the container running the agent) | this repo, `infra/ci/`, dev environment only |
  | Runner registration/permissions | a GitHub org runner group, restricted to first-party repos, public-repo access off, fork-PR approval required |
  | Reusable workflow definitions | the org's `.github` repo |
  | Thin workflow callers | each app repo, calling the reusable workflows above |

  There is deliberately **no separate CI/CD repo**. Deployment logic is
  Komodo, pull-based, watching `environments/<env>/` in this repo — not
  workflow code running somewhere and pushing out changes.

- **prod is pull-only via Komodo.** No runner — self-hosted or
  GitHub-hosted — ever deploys to prod. dev and prod are separate
  hosts/VMs; each holds only its own age key (decision 6); they never
  share a Docker daemon, an edge network, or a Traefik instance.

**⚠️ A runner with access to the host's Docker socket is effectively root
on that host.** This is acceptable *only* because the dev host runs
trusted code exclusively and holds only the dev age key — never the prod
key, never anything a compromised runner could use to reach production.
Untrusted code (any fork PR on a public repo) stays on GitHub-hosted
runners, full stop, regardless of how convenient a self-hosted runner
might seem for a one-off case.

## Per-PR sandboxes

Same status as the rest of this document: agreed design, nothing built.
`pr-<n>-<app>` Compose project names on the dev host are already the
isolation unit — many PR sandboxes can run side by side on the same host
with no extra infrastructure, since a distinct project name namespaces
containers/networks/volumes on its own.

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
get a real hostname (`pr-<n>-<app>.dev.${DOMAIN}`) rather than existing
only for automated tests hit over the internal compose network. This is
affordable specifically because `dev`'s own `DOMAIN` should be a subdomain
of the root (e.g. `dev.quarantine.al`, not the bare root domain) — the
wildcard-cert mechanism already in `infra/edge/traefik/` requests
`main=${DOMAIN}` + `sans=*.${DOMAIN}`, exactly one level of wildcard. With
`dev`'s `DOMAIN` one level down from the root, that wildcard already covers
`pr-<n>-<app>.dev.${DOMAIN}` (one level below `dev.${DOMAIN}`) with **zero
additional cert or DNS work per PR** — no per-PR Cloudflare API calls, no
per-PR ACME requests. If `dev` instead shared the bare root domain, a PR
hostname would sit two levels down, outside that single wildcard, and
would need its own per-PR DNS-01 request — real, avoidable complexity that
the subdomain choice sidesteps entirely.

Routing itself needs no new mechanism: Traefik already does dynamic
label-based discovery for every service in this platform. A PR sandbox's
compose invocation just needs its own Traefik labels with a templated
`Host()` rule (`pr-${PR_NUMBER}-${APP_NAME}.dev.${DOMAIN}`) — same
mechanism every other service already uses, just parameterized per PR.

A first-party app with no reviewer-facing UI (headless/API-only) can opt
out of the preview labels and run its CI against the sandbox over the
internal compose network only — an escape hatch, not the default.

## What this doc does not cover

Implementation: the actual `infra/ci/github-runner/` compose fragment, the
reusable workflow templates in the org `.github` repo, the reap-mode
additions to `postgres.sh`/`zitadel.sh` described above, and the
PR-environment workflow itself (open/push/close triggers, the compose
invocation that threads `PR_NUMBER`/`APP_NAME` through). All of that is
separate, future work.
