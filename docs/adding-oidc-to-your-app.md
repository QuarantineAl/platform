# Adding OIDC to your app

This is the self-service recipe for fronting a catalog app with Zitadel
OIDC via the shared oauth2-proxy sidecar — `catalog.yaml` already promises
this per-app (`needs_oidc`), and this doc is what makes flipping that flag
a real, walk-through-able path instead of a special case per app.

**The bar this recipe holds itself to**: adding OIDC to a new app touches
only that app's own three places — its `catalog.yaml` entry, its own
`compose.yaml`, and its own new block in
`infra/edge/oauth2-proxy/compose.yaml`. Nothing shared (`bin/quarantine`,
`provisioners/zitadel.sh`, any other app's files, or the reusable CI
workflows in `QuarantineAl/.github`) should need editing — including, for
an app that's also PR-sandboxed, the CI wiring that registers and
deregisters each PR's own redirect URI. If following this doc requires
touching something outside those three places, that's a regression in the
generalization, not a normal part of onboarding — see "Known platform
gaps" at the end for the one place this bar isn't fully met yet.

Read `docs/adding-an-app.md` first if you haven't added a catalog app
before — this doc only covers the OIDC-specific slice of that process
(`docs/adding-an-app.md` §3.2/§3.3 point here for the OIDC half).

## Three shapes

Every consumer needs one new named `oauth2-proxy-<app>` service in
`infra/edge/oauth2-proxy/compose.yaml`, but the recipe forks along two
independent axes: how many hostnames your app serves from, and whether
it's also PR-sandboxed (per-PR preview deployments, see
`docs/runners-and-sandboxing.md`).

| | Single-origin | Multi-origin |
|---|---|---|
| **Never PR-sandboxed** | Uptime Kuma: one hostname, one instance, simplest case | (no example yet — would follow Lazaretto's cookie-domain handling, skip its SUBDOMAIN-templating) |
| **PR-sandboxed** | (no example yet — would follow Lazaretto's SUBDOMAIN-templating, skip its cookie-domain handling) | Lazaretto: frontend + API on sibling subdomains, one instance per open PR sandbox plus the persistent deployment |

**Single-origin, never-sandboxed** (Uptime Kuma's `status.${DOMAIN}`) is
the simple case — copy the `oauth2-proxy-uptime-kuma` block verbatim,
rename every `-uptime-kuma` suffix to `-<app>`, and point
`OAUTH2_PROXY_REDIRECT_URL` / the router's `Host()` at your app's own
subdomain. No `OAUTH2_PROXY_COOKIE_DOMAINS`, no `${SUBDOMAIN}` templating,
no `add-redirect`/`remove-redirect` calls needed.

**Multi-origin and/or PR-sandboxed** (Lazaretto) needs the fuller recipe
below — copy the `oauth2-proxy-lazaretto` block instead, and apply
whichever of its two techniques (cookie-domain handling for multi-origin,
`${SUBDOMAIN}` templating + redirect registration for PR-sandboxed) your
app actually needs. They're independent: a PR-sandboxed single-origin app
would take the `${SUBDOMAIN}` templating and the `add-redirect`/
`remove-redirect` CI wiring, but skip `OAUTH2_PROXY_COOKIE_DOMAINS`.

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
oauth2-proxy instance's own router (see step 2) only ever needs to live on
that one host, regardless of how many other origins it also protects.

Only the **persistent** deployment's redirect URI goes in `catalog.yaml`.
If your app is also PR-sandboxed, every PR sandbox's own redirect URI is
registered dynamically (`add-redirect`/`remove-redirect`, step 4) against
this SAME Application — not listed statically here, and not a second
catalog entry.

### 2. `infra/edge/oauth2-proxy/compose.yaml`

Copy the matching block (`oauth2-proxy-uptime-kuma` for the simple case,
`oauth2-proxy-lazaretto` if you need either multi-origin or PR-sandboxed
handling) and rename every `-<app>` suffix: service key, `container_name`,
`profiles`, the two `OIDC_CLIENT_ID_<APP>`/`OIDC_CLIENT_SECRET_<APP>` env
var references, and every router/service/middleware name. Traefik
aggregates middleware and router definitions project-wide regardless of
which compose file declares them, so these names must stay unique across
every consumer in this one file — a collision silently steals traffic or
breaks unrelated apps instead of erroring at startup.

**If your app is multi-origin**, three settings need to change together:

| Setting | Value | Why |
|---|---|---|
| `OAUTH2_PROXY_COOKIE_DOMAINS` | `.${DOMAIN}` (the shared parent) | Without this, the cookie set while visiting the frontend is never sent on the browser's calls to the API host — login appears to succeed, then every API call comes back unauthenticated. **Fails silently** — nothing logs a cookie-domain mismatch. |
| `OAUTH2_PROXY_COOKIE_NAME` | a per-app-unique name, e.g. `_oauth2_proxy_<app>` | oauth2-proxy defaults every instance to the same cookie name (`_oauth2_proxy`). Once `COOKIE_DOMAINS` broadens past your app's own host, that cookie is also sent to *every other app's* host under `${DOMAIN}` — colliding with any other single-origin consumer's own same-named, host-scoped cookie in the same `Cookie` header. Skipping this is the one broadening step that looks harmless and isn't. |
| Router `Host()` / `OAUTH2_PROXY_REDIRECT_URL` | the frontend host only | `/oauth2/callback` and `/oauth2/sign_in` only need to be reachable on one host — pick the frontend, since that's where users land first. |
| API host's Traefik router | add a second, `Method(`OPTIONS`)`-matched router at higher priority with **no** oauth2 middlewares, pointed at the same backend service | A browser's CORS preflight never carries credentials (Fetch spec), so forwardAuth always sees it as unauthenticated and answers with the sign-in redirect — which browsers refuse to follow on a preflight, failing every cross-origin fetch before it's even sent. Confirmed live against lazaretto: see `apps/first-party/lazaretto/compose.yaml`'s `-api-preflight` router for the exact shape. Only matters if your frontend and API are different hosts *and* your frontend's requests trigger a preflight (any non-simple header, e.g. `Content-Type: application/json`, or credentialed cross-origin `fetch`) — a same-origin build never hits this. |

**If your app is PR-sandboxed** (regardless of single- or multi-origin),
template everything that identifies an instance by `${SUBDOMAIN}` —
`container_name`, every router/service/middleware name, and
`OAUTH2_PROXY_REDIRECT_URL` itself — but leave `OAUTH2_PROXY_CLIENT_ID`/
`CLIENT_SECRET`/`COOKIE_SECRET`/`COOKIE_NAME` untemplated. Every instance
(persistent + every open PR sandbox) is a different Traefik router/service
answering a different host, but they all share ONE Zitadel Application and
ONE session cookie — that's what makes an already-logged-in user's cookie
valid across the persistent deployment and any PR sandbox they visit, and
what makes `add-redirect`/`remove-redirect` (step 4) meaningful: they add
or remove one entry from that ONE Application's redirect list, not create
a new Application per PR.

`forwardauth.address` must target the **container name**
(`http://quarantine-oauth2-proxy-${SUBDOMAIN:-<app>}:4180/oauth2/auth`),
never the compose service key — a service key can't itself be
`${VAR}`-templated, so every concurrently-running instance would share one
Docker DNS alias and Docker would round-robin forwardAuth calls between
whichever PR sandboxes happen to be open, non-deterministically routing
one PR's auth check to a completely different PR's oauth2-proxy instance.

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

**If you're PR-sandboxed**, template the label's *key* AND the middleware
names in its *value* — unlike the shared-instance case, there's a
different `oauth2-proxy-<app>` instance (and therefore different
`oauth2-auth-<app>`/`oauth2-errors-<app>` middlewares) per SUBDOMAIN:

```yaml
      - traefik.http.routers.${SUBDOMAIN:-<app>}.middlewares=oauth2-errors-${SUBDOMAIN:-<app>},oauth2-auth-${SUBDOMAIN:-<app>}
```

If your app also has a bare `Host()` router that isn't itself the
oauth2-proxy instance's own path-scoped router, give it an explicit,
lower `priority` than the oauth2-proxy router's `100` — otherwise that
catch-all router also matches `/oauth2/*` requests on the same host and
Traefik's tie-break becomes ambiguous. See Lazaretto's frontend router
(`priority: 10`) for a worked example.

### 4. PR-sandboxed only: nothing to touch in CI

If your app is PR-sandboxed, `QuarantineAl/.github`'s `pr-sandbox-up.yml`/
`pr-sandbox-down.yml` already:

- bring up (or tear down) your app's own `oauth2-proxy-<app>` instance
  alongside its containers, in the same per-PR Compose project, whenever
  `catalog.yaml`'s `<app>.needs_oidc` is `true`;
- call `quarantine app add-redirect <app> https://pr-<n>-<app>.<domain>/oauth2/callback`
  when the sandbox comes up, and the matching `remove-redirect` when it
  closes.

Both are driven entirely by `catalog.yaml`'s own `needs_oidc` flag for
whichever `app` input was passed in — there is no per-app name check to
extend. Nothing in either workflow needs editing for a new PR-sandboxed
`needs_oidc` app; it gets this for free the moment its catalog entry sets
`needs_oidc: true` and it opts into calling `pr-sandbox-up.yml`/
`pr-sandbox-down.yml` at all (an app's own choice, made in its own thin
caller workflow — see `docs/runners-and-sandboxing.md`).

`quarantine app add-redirect`/`remove-redirect` (`bin/quarantine`) are the
CI-facing entry points — they decrypt secrets, validate the app is a
`needs_oidc` catalog entry, and call `provisioners/zitadel.sh`'s matching
mode, which does the actual Zitadel `UpdateApplication` read-modify-write
(there's no per-URI add/remove RPC, only a full-list replace), serialized
with `flock` so two PRs opening/closing at once can't lose an update to
each other. You'd only ever call these by hand for debugging; CI is the
only real caller.

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
- **Exclude your own Docker healthcheck endpoint from whatever gates every
  other route.** A container healthcheck (e.g. `wget -qO- http://
  127.0.0.1:<port>/health` in your app's own `compose.yaml`) runs *inside*
  the container and never goes through Traefik — it carries no forwarded
  identity and never will. If your backend applies its JWT-verification
  middleware/guard globally with no carve-out, `AUTH_MODE=required` 401s
  the healthcheck itself: most HTTP clients (`wget` included) treat any
  4xx as a failure, so Docker reports a perfectly healthy container as
  unhealthy forever — which then also breaks `wait_healthy()` in every
  future deploy that waits on it. Hit exactly this onboarding Lazaretto:
  the container booted and served real requests fine the whole time, but
  never left "unhealthy" until `/health` was excluded (see
  `backend/src/app.module.ts`'s `AppModule.configure()` in the lazaretto
  repo for the fix). Nothing else needs a carve-out — only the one path
  your own compose file's healthcheck actually hits.

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
   compose.yaml` (copy-rename, applying whichever of the multi-origin/
   PR-sandboxed techniques above it actually needs).
3. Its own `compose.yaml`'s router `middlewares` labels.

That's it — even if the new app is PR-sandboxed. Nothing in `bin/quarantine`
needs editing (`OIDC_CLIENT_ID_<APP>`/`OIDC_CLIENT_SECRET_<APP>` injection,
the deferred-secret bootstrapping, and `add-redirect`/`remove-redirect` are
all driven off `catalog.yaml`'s `needs_oidc` entries, the same way
`<APP>_VERSION` is already driven off the manifest), and nothing in
`QuarantineAl/.github`'s `pr-sandbox-up.yml`/`pr-sandbox-down.yml` needs
editing either (see step 4 above). Adding a documentation placeholder for
the new app under `apps:` in `environments/_template/secrets.example.yaml`
(mirroring the `lazaretto`/`uptime-kuma` entries) is good practice but not
required — `generate_secrets` creates the key either way.

## Known platform gaps

One thing stops this recipe from being 100% turnkey today — real,
deliberately deferred rather than silently worked around:

- **No reap mode for a closed PR's database.** `postgres.sh` has no
  teardown mode (`docs/runners-and-sandboxing.md` already flags this
  generally) — unrelated to OIDC, but worth naming here since it's the one
  remaining gap in the overall PR-sandbox story: a `needs_db` PR sandbox
  leaves its database/role behind after the PR closes, while a `needs_oidc`
  one now cleans up fully (redirect URI deregistered, containers torn
  down). Platform-wide provisioner work, not something to work around
  per-app — raise it again if it becomes load-bearing rather than
  re-solving it inline in a new app's onboarding.
