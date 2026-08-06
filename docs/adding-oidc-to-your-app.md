# Adding OIDC to your app

This is the self-service recipe for fronting a catalog app with Zitadel
OIDC via the shared oauth2-proxy sidecar — `catalog.yaml` already promises
this per-app (`needs_oidc`), and this doc is what makes flipping that flag
a real, walk-through-able path instead of a special case per app.

**The bar this recipe holds itself to**: adding OIDC to a new app touches
only that app's own three places — its `catalog.yaml` entry, its own
`compose.yaml`, and its own new block in
`infra/edge/oauth2-proxy/compose.yaml`. Nothing shared (`bin/quarantine`,
`provisioners/zitadel.sh`, any other app's files) should need editing. If
following this doc requires touching something outside those three places,
that's a regression in the generalization, not a normal part of onboarding
— see "Known platform gaps" at the end for the two places this bar isn't
fully met yet.

Read `docs/adding-an-app.md` first if you haven't added a catalog app
before — this doc only covers the OIDC-specific slice of that process
(`docs/adding-an-app.md` §3.2/§3.3 point here for the OIDC half).

## Two shapes: single-origin and multi-origin

Every consumer needs one new named `oauth2-proxy-<app>` service in
`infra/edge/oauth2-proxy/compose.yaml`, but the recipe forks depending on
whether your app serves everything from one hostname or from several
sibling subdomains.

**Single-origin** (one hostname, e.g. Uptime Kuma's `status.${DOMAIN}`) is
the simple case — copy the `oauth2-proxy-uptime-kuma` block in that file
verbatim, rename every `-uptime-kuma` suffix to `-<app>`, and point
`OAUTH2_PROXY_REDIRECT_URL` / the router's `Host()` at your app's own
subdomain. No `OAUTH2_PROXY_COOKIE_DOMAINS` needed — the cookie defaults to
scoping itself to the single host it was issued from, which is exactly
right when there's only one host.

**Multi-origin** (frontend + API on sibling subdomains, e.g. Lazaretto's
`lazaretto.${DOMAIN}` / `lazaretto-api.${DOMAIN}`) needs the fuller recipe
below — copy the `oauth2-proxy-lazaretto` block instead. One oauth2-proxy
instance still fronts every origin; the differences are all about making
one session cookie valid across hosts that don't share an origin.

### 1. `catalog.yaml`

```yaml
  - name: <app>
    kind: app
    compose_path: apps/<kind>/<app>/compose.yaml
    subdomain: <app>
    needs_db: false
    needs_oidc: true
    oidc_redirect_uris:
      - "https://<app>.${DOMAIN}/oauth2/callback"
```

`provisioners/zitadel.sh` **dies** if `needs_oidc: true` and
`oidc_redirect_uris` is missing or empty — this isn't optional. For a
multi-origin app, only the **frontend** host's callback goes here; the
oauth2-proxy instance's own router (see step 3) only ever needs to live on
that one host, regardless of how many other origins it also protects.

Don't add a redirect URI per PR sandbox here. `zitadel.sh` resolves
`oidc_redirect_uris` by exact `name` match against this file — a PR
sandbox invoked as `pr-<n>-<app>` won't match any entry here at all (see
"Known platform gaps" below). PR sandboxes ride the same shared
Application and the same shared cookie instead; nothing about that needs a
second redirect URI registered.

### 2. `infra/edge/oauth2-proxy/compose.yaml`

Copy the matching block (`oauth2-proxy-uptime-kuma` for single-origin,
`oauth2-proxy-lazaretto` for multi-origin) and rename every `-<app>`
suffix: service key, `container_name`, `profiles`, the two
`OIDC_CLIENT_ID_<APP>`/`OIDC_CLIENT_SECRET_<APP>` env var references, and
every router/service/middleware name. Traefik aggregates middleware and
router definitions project-wide regardless of which compose file declares
them, so these names must stay unique across every consumer in this one
file — a collision silently steals traffic or breaks unrelated apps
instead of erroring at startup.

For a multi-origin app, three settings need to change together, not
independently:

| Setting | Value | Why |
|---|---|---|
| `OAUTH2_PROXY_COOKIE_DOMAINS` | `.${DOMAIN}` (the shared parent) | Without this, the cookie set while visiting the frontend is never sent on the browser's calls to the API host — login appears to succeed, then every API call comes back unauthenticated. **Fails silently** — nothing logs a cookie-domain mismatch. |
| `OAUTH2_PROXY_COOKIE_NAME` | a per-app-unique name, e.g. `_oauth2_proxy_<app>` | oauth2-proxy defaults every instance to the same cookie name (`_oauth2_proxy`). Once `COOKIE_DOMAINS` broadens past your app's own host, that cookie is also sent to *every other app's* host under `${DOMAIN}` — colliding with any other single-origin consumer's own same-named, host-scoped cookie in the same `Cookie` header. Skipping this is the one broadening step that looks harmless and isn't. |
| Router `Host()` / `OAUTH2_PROXY_REDIRECT_URL` | the frontend host only, fixed literal (not templated) | `/oauth2/callback` and `/oauth2/sign_in` only need to be reachable on one host — pick the frontend, since that's where users land first. |

The forwardAuth middleware this instance defines (`oauth2-auth-<app>`,
`oauth2-errors-<app>`) gets attached to **every** router that needs
protecting — for Lazaretto, both the frontend and the `-api` router, since
neither has a legitimate unauthenticated path. A single-origin app with a
genuine public/private split (Uptime Kuma's status pages vs. admin UI)
attaches it only to the private router — see that app's own compose
fragment for the two-router pattern.

### 3. Your app's own `compose.yaml`

Attach the middleware to every router that needs gating:

```yaml
      - traefik.http.routers.<your-router>.middlewares=oauth2-errors-<app>,oauth2-auth-<app>
```

Order matters: `oauth2-errors-<app>` must be **outer** (listed first),
`oauth2-auth-<app>` **inner** (listed second). Middlewares apply
outer-to-inner; reversed, the 401 forwardAuth short-circuits with hits the
browser directly instead of getting rewritten into a 302 to
`/oauth2/sign_in`.

**If your router names are `${SUBDOMAIN}`-templated** (any app also
invoked directly for PR sandboxes, per `docs/runners-and-sandboxing.md` —
Lazaretto is the first of these), template the label's *key* but not its
*value*:

```yaml
      - traefik.http.routers.${SUBDOMAIN:-<app>}.middlewares=oauth2-errors-<app>,oauth2-auth-<app>
```

The left-hand side (which router) varies per invocation — a PR sandbox's
own `pr-5-<app>` router gets this label too, automatically. The right-hand
side (which middleware, i.e. which oauth2-proxy instance) stays a fixed
literal: there is still only ONE `oauth2-proxy-<app>` instance, shared by
the persistent deployment and every PR sandbox — never one per SUBDOMAIN.

If your app also has a bare `Host()` router that isn't itself the
oauth2-proxy instance's own path-scoped router, give it an explicit,
lower `priority` than the oauth2-proxy router's `100` — otherwise that
catch-all router also matches `/oauth2/*` requests on the same host and
Traefik's tie-break becomes ambiguous. See Lazaretto's frontend router
(`priority: 10`) for a worked example.

## The forwarded-identity contract

This is the platform's standard contract for every first-party app that
needs real user identity, not just Lazaretto's. Get this right once here;
every future first-party app should be able to just follow it.

- **`OAUTH2_PROXY_PASS_AUTHORIZATION_HEADER: "true"`** — not `SET_`. These
  are two different options that are easy to confuse: `PASS_` forwards
  the raw ID token to the upstream app as `Authorization: Bearer
  <id_token>`, on every request. `SET_` is a differently-scoped option
  that sets a header on an Nginx-`auth_request`-style auth-subrequest
  *response* — not the request your app actually receives. Only `PASS_`
  gets your app a token to verify.
- **`OAUTH2_PROXY_SCOPE`** must include, at minimum:
  - `openid email profile` — standard claims.
  - `urn:zitadel:iam:user:resourceowner` — the user's Zitadel org id.
  - `urn:zitadel:iam:org:projects:roles` — plural, no project id needed.
    Requests the `urn:zitadel:iam:org:project:<id>:roles` claim for
    whichever Zitadel project your app's OIDC client belongs to (the
    shared `quarantine-apps` project for every catalog app today) —
    without your app or this compose file ever needing to know that
    project's id statically. If a role claim you expect isn't showing up
    in the forwarded token, check the Zitadel application's own "User
    Roles Inside ID Token" setting in the console before assuming the
    scope is wrong.
- **Your backend MUST verify the forwarded JWT itself** — signature and
  expiry, against Zitadel's JWKS (`<issuer>/oauth/v2/keys`, `jose`'s
  `createRemoteJWKSet` + `jwtVerify` is the reference tool). This is
  defense in depth: the network topology (no published ports on your
  backend, `edge` network only) already prevents bypassing Traefik, but
  the JWT verification is the actual security boundary, and it should
  hold even if that topology assumption is ever wrong. Don't just trust
  the forwarded headers because they arrived from inside the `edge`
  network.
- **The issuer is environment-provided, not hardcoded**: `auth.dev.
  quarantine.al` in dev, `auth.quarantine.al` in prod — same shape as
  `OAUTH2_PROXY_OIDC_ISSUER_URL: https://auth.${DOMAIN}` above. Read it
  from an env var your app's own compose service sets (Lazaretto's
  backend reads `ZITADEL_ISSUER_URL`), never a literal string in your
  app's own source.

**Lazaretto's backend is the reference implementation of this contract —
link to it, don't duplicate it.** See `backend/src/auth/auth.service.ts`
and `backend/src/auth/auth-config.ts` in the lazaretto repo for the actual
`AUTH_MODE` switch, JWKS verification, and role-claim scanning
(`ROLE_CLAIM_PATTERN`, matching the `projects:roles` scope above without
needing a `ZITADEL_PROJECT_ID` config entry) this whole section describes.
Its own design doc, `docs/USER_MANAGEMENT_OIDC_ZITADEL.md` in that repo,
has the full narrative (session strategy, logout, Socket.IO handshake
auth, data model) for the app side of this pattern.

## Local development

None of the above applies to plain local dev — running your app directly
(`npm run start:dev` + Vite, or equivalent) never goes through Traefik or
oauth2-proxy at all, so there's no forwarded token to verify. Your app
needs its own explicit switch (Lazaretto's is `AUTH_MODE=required | off`,
defaulting to `off`) so local dev and CI unit tests keep working with no
forwarded identity, while every real deployment (persistent or PR sandbox
— anything that actually goes through this compose fragment) sets it to
`required`.

## Reference: what the next app after Lazaretto touches

Onboarding a third `needs_oidc` app should touch exactly:

1. Its own `catalog.yaml` entry (`needs_oidc: true` + `oidc_redirect_uris`).
2. A new `oauth2-proxy-<app>` block in `infra/edge/oauth2-proxy/
   compose.yaml` (copy-rename, per the table above if multi-origin).
3. Its own `compose.yaml`'s router `middlewares` labels.

Nothing in `bin/quarantine` needs editing — `OIDC_CLIENT_ID_<APP>`/
`OIDC_CLIENT_SECRET_<APP>` injection and the deferred-secret bootstrapping
are both driven off `catalog.yaml`'s `needs_oidc` entries, the same way
`<APP>_VERSION` is already driven off the manifest. Adding a documentation
placeholder for the new app under `apps:` in `environments/_template/
secrets.example.yaml` (mirroring the `lazaretto`/`uptime-kuma` entries) is
good practice but not required — `generate_secrets` creates the key either
way.

## Known platform gaps

Two things stop this recipe from being 100% turnkey today — both real,
both deliberately deferred rather than silently worked around:

- **PR sandboxes don't get their own redirect URI.** `zitadel.sh` resolves
  `oidc_redirect_uris` by exact `catalog.yaml` name match; a PR sandbox
  named `pr-<n>-<app>` matches nothing. The shared-Application model this
  doc assumes (one `client_id`/`client_secret`, one registered redirect
  URI, reused by every PR sandbox via the same cookie/session mechanism)
  works today because PR sandboxes never register their own callback —
  they just ride the persistent deployment's. If a future need arises for
  a PR sandbox to have its *own* redirect URI (rather than sharing), that
  requires `zitadel.sh` to support a read-modify-write against Zitadel's
  `UpdateApplication` (which replaces the whole `redirectUris` list, not a
  single add/remove) plus serializing concurrent PR open/close events
  against the same Application — real provisioner work, not a config
  change, and a convention change affecting every app's PR sandboxes, not
  just one. Not built. PR sandboxes stay functional without it; they're
  just not independently revocable from the persistent deployment's OIDC
  client.
- **No reap mode for closed PRs.** Neither `postgres.sh` nor `zitadel.sh`
  tears anything down when a PR closes (`docs/runners-and-sandboxing.md`
  already flags this generally). For OIDC specifically, this is lower
  stakes than it sounds under the shared-Application model above — a
  closed PR sandbox doesn't leave behind its own client secret, just an
  inert hostname that no longer resolves.

Both are platform-wide provisioner decisions, not something to work around
per-app — raise them again if they become load-bearing rather than
re-solving them inline in a new app's onboarding.
