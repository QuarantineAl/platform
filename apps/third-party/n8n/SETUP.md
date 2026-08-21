# n8n — one-time manual setup

Everything mechanical (compose fragment, catalog entry, DB/OIDC
provisioning, secrets generation) is handled by `quarantine start` once
`n8n` is in an environment's `manifest.yaml`. The steps below are the part
that genuinely has no automation — either because they're an interactive,
one-shot decision (the owner account) or because they live outside this
platform's provisioners entirely (Lazaretto's own headless-API contract).

Do them in this order, after the first `quarantine start` that brings n8n
up healthy.

## 1. Zitadel: role + machine user for Lazaretto's headless API

Corrects an assumption worth naming: this platform has **one shared
Zitadel project** (`quarantine-apps`, see `provisioners/zitadel.sh`'s own
header), not a separate project per app. A role added "for Lazaretto" is
really added to that one shared project — every app's OIDC client in it can
request it via the `urn:zitadel:iam:org:projects:roles` scope already
listed in `docs/adding-oidc-to-your-app.md`.

Also corrects the earlier version of this doc, which pointed at the Zitadel
Console for the machine user itself: `quarantine machine onboard` now does
the whole thing — role, machine user, client secret, and the grant — in one
idempotent, re-runnable command (`provisioners/zitadel.sh`'s new
`machine-*` modes; **not** a Project Application — see that file's own
header for why a machine user alone is the correct primitive here):

```bash
./bin/quarantine app add-role n8n agent:invoke \
  --display-name "Invoke Lazaretto headless tasks"

./bin/quarantine machine onboard n8n-automation \
  --grant n8n agent:invoke \
  --display-name "n8n workflow automation"
```

(The `n8n` argument to both commands is only used for usage/logging and for
`_require_oidc_app`'s sanity check that `n8n` is a real `needs_oidc`
catalog app — the role itself always lives on the one shared project,
regardless of which catalog app name is passed.)

The client secret is shown exactly once, at creation — copy it immediately
for step 4 below. If you lose it before pasting it into n8n, it's still
retrievable (without regenerating, which would break any credential
already configured with the old one):

```bash
./bin/quarantine machine show n8n-automation
```

**This machine-user automation is new and, as of this writing, unconfirmed
against a live Zitadel instance** (every other API call in
`provisioners/zitadel.sh` was fixed at least once after disagreeing with
its own documentation, once tried live — see that file's own header). If
`machine onboard` fails outright, `provisioners/zitadel.sh`'s header
comment on its `machine-*` modes names exactly which parts are uncertain
(the create-user endpoint path and response field); fall back to the
Zitadel Console's own Service Users screen for this one onboarding if it
doesn't resolve quickly, and please fix the script once you know what was
wrong.

## 2. Zitadel / oauth2-proxy: nothing to do here

Listed in some checklists as a step ("ensure the oauth2-proxy app config
covers n8n.${DOMAIN}") — it isn't one for this platform. `catalog.yaml`'s
`n8n` entry (`oidc_redirect_uris`) already drives
`provisioners/zitadel.sh`'s default `ensure` mode, which `quarantine start`
calls automatically for every `needs_oidc` app in the manifest — the
OIDC Application backing `oauth2-proxy-n8n` (see
`infra/edge/oauth2-proxy/compose.yaml`) is created/healed the same way
every other consumer's is. If `https://n8n.${DOMAIN}` doesn't prompt for
sign-in correctly after the first `quarantine start`, that's a bug to
investigate, not a missing manual step.

## 3. First login: create the owner account

n8n's own first-run flow. Visit `https://n8n.${DOMAIN}` (behind the
forward-auth gate — sign in with Zitadel first), then complete n8n's
"Set up owner account" screen with local credentials. This is the **only**
local n8n account this platform's model calls for — everyone else reaches
the editor via the same Zitadel-backed forward-auth session; n8n itself
has no idea any of that happened.

## 4. In n8n: OAuth2 (client credentials) credential for Lazaretto

Editor → Credentials → New → **OAuth2 API** (or the closest n8n credential
type supporting the client-credentials grant):

- Grant Type: Client Credentials
- Access Token URL: `https://auth.${DOMAIN}/oauth/v2/token`
- Client ID: `n8n-automation` (a machine user's username IS its client_id)
- Client Secret: from step 1's `machine onboard` output, or
  `./bin/quarantine machine show n8n-automation`
- Scope: at minimum whatever Lazaretto's headless API documents as required
  for `agent:invoke` (see step 5)

No credential JSON or workflow content is committed anywhere — n8n's own
encrypted-at-rest credential store (via `N8N_ENCRYPTION_KEY`) is the only
copy, by design (see `apps/third-party/n8n/workflows/README.md` for what
*does* get committed).

## 5. Lazaretto's headless API contract

Reference, in the `lazaretto` repo, before building any workflow that calls
Lazaretto:

- `docs/headless-api.md` — the task API surface itself.
- The `X-Callback-Secret` header — must equal the value n8n's own
  container sees as `CALLBACK_STATIC_SECRET` (stored in secrets.sops.yaml
  and exported to n8n's `.env` as `CALLBACK_STATIC_SECRET_N8N` — see
  `apps/third-party/n8n/compose.yaml`'s own comment and `catalog.yaml`'s
  `generated_secrets` entry for this app). Generated automatically on
  n8n's first `quarantine start` unless Lazaretto already has a fixed
  value, in which case override `.apps["n8n"].callback_static_secret` via
  `secrets_edit` before that first start instead.
- Direction matters: workflows call OUT to Lazaretto's headless API using
  the OAuth2 credential from step 4 (over whatever host Lazaretto's own
  docs specify). The *callback* runs the other way — when a long-running
  Lazaretto task finishes, Lazaretto resumes the waiting workflow by
  hitting n8n's own Wait-node resume URL directly at
  `http://quarantine-n8n:5678/webhook-waiting/<id>` over the internal
  `edge` Docker network — **never** through Traefik or `n8n.${DOMAIN}`,
  regardless of environment. That's also why `/webhook-waiting/*` is in
  `n8n-public`'s bypass list (`apps/third-party/n8n/compose.yaml`): even
  though this particular caller never goes through Traefik, the same path
  prefix has to stay reachable for any resume that does arrive externally.
