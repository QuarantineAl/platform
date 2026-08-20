# n8n — one-time manual setup

Everything mechanical (compose fragment, catalog entry, DB/OIDC
provisioning, secrets generation) is handled by `quarantine start` once
`n8n` is in an environment's `manifest.yaml`. The steps below are the part
that genuinely has no automation — either because they're an interactive,
one-shot decision (the owner account) or because they live outside this
platform's provisioners entirely (Lazaretto's own headless-API contract).

Do them in this order, after the first `quarantine start` that brings n8n
up healthy.

## 1. Zitadel: role for Lazaretto's headless API

Corrects an assumption worth naming: this platform has **one shared
Zitadel project** (`quarantine-apps`, see `provisioners/zitadel.sh`'s own
header), not a separate project per app. A role added "for Lazaretto" is
really added to that one shared project — every app's OIDC client in it can
request it via the `urn:zitadel:iam:org:projects:roles` scope already
listed in `docs/adding-oidc-to-your-app.md`.

Defining the role itself is NOT a console step — `quarantine app add-role`
is an existing idempotent CLI command that wraps `provisioners/zitadel.sh
app-add-role` (create-or-no-op, safe to re-run):

```bash
./bin/quarantine app add-role n8n agent:invoke \
  --display-name "Invoke Lazaretto headless tasks"
```

(The `n8n` argument is only used for the command's own usage/logging —
`app-add-role` writes to the one shared project regardless of which
catalog app name is passed. Confirmed by reading `provisioners/zitadel.sh`
directly: `app-add-role`'s role-write path never references its
`<canonical_name>` argument.)

What still has no CLI and must be done in the Zitadel Console
(`https://auth.${DOMAIN}/ui/v2/login` → Console), because
`provisioners/zitadel.sh`'s `user-*` modes are explicitly for human,
email-identified accounts (its own header: "Human identity management"),
not machine/service accounts:

1. Console → Users → **Service Users** → create a new machine user named
   `n8n-automation`, auth method **Client Credentials** (Basic Auth or
   Client Secret Basic, not JWT).
2. Generate a client secret for it — copy it immediately, Zitadel shows it
   exactly once.
3. Grant it the `agent:invoke` role on the shared `quarantine-apps` project
   (Console → Projects → quarantine-apps → Authorizations → grant to the
   `n8n-automation` service user).

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
- Client ID / Client Secret: from step 1
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
- The `X-Callback-Secret` header — must equal this environment's
  `CALLBACK_STATIC_SECRET` (see `apps/third-party/n8n/compose.yaml`'s own
  comment and `catalog.yaml`'s `generated_secrets` entry for this app —
  generated automatically on n8n's first `quarantine start` unless
  Lazaretto already has a fixed value, in which case override it via
  `secrets_edit` before that first start instead).
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
