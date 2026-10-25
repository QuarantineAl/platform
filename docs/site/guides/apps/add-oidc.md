---
title: Add OIDC to an app
description: Put an app behind Zitadel sign-in with an oauth2-proxy sidecar, or wire native OIDC, and the identity contract backends must follow.
sidebar:
  order: 2
---

There are two ways an app gets Zitadel sign-in:

| Pattern | Use when | Examples |
|---|---|---|
| **oauth2-proxy forward-auth** | The whole host should require sign-in and the app has no OIDC code | Lazzaretto, delivery-note-ai, n8n, uptime-kuma |
| **Native OIDC** | Some pages must stay public, or non-browser clients cannot carry a proxy cookie | Kujtime, Vaultwarden |

Both start the same way: in `catalog.yaml` set `needs_oidc: true` and list the
callback.

```yaml title="catalog.yaml"
  - name: myapp
    kind: app
    compose_path: apps/first-party/myapp/compose.yaml
    subdomain: myapp
    needs_db: false
    needs_oidc: true
    oidc_redirect_uris:
      - "https://myapp.${DOMAIN}/oauth2/callback"
```

On the next `quarantine start` with `myapp` in the manifest,
`provisioners/zitadel.sh` creates an OIDC application named `myapp` in the
`quarantine-apps` project (code flow, refresh tokens, web app,
`client_secret_basic`, `idTokenUserinfoAssertion: true`), stores the client id
and secret in `secrets.sops.yaml`, and exports `OIDC_CLIENT_ID_MYAPP` and
`OIDC_CLIENT_SECRET_MYAPP` into the environment's `.env`. List only the
persistent host's callback; tenants and PR sandboxes add their own at runtime
with `quarantine app add-redirect`.

## Pattern 1: oauth2-proxy sidecar

### Add a proxy block

Copy a block in `infra/edge/oauth2-proxy/compose.yaml` and rename every
`-<app>` suffix (service key, `container_name`, `profiles`, the two OIDC
variables, and every router, service and middleware name; Traefik names are
global, so collisions break other apps silently):

- **Single host, no PR sandboxes**: copy `oauth2-proxy-delivery-note-ai` (or
  `-n8n`). Give it a unique `OAUTH2_PROXY_COOKIE_NAME`.
- **Several hosts (frontend + API) or PR-sandboxed**: copy
  `oauth2-proxy-lazzaretto`.

Key settings:

| Setting | Value | Why |
|---|---|---|
| `OAUTH2_PROXY_OIDC_ISSUER_URL` | `https://auth.${DOMAIN}` | Per-environment issuer |
| `OAUTH2_PROXY_EMAIL_DOMAINS` | `"*"` | Any signed-in user of the environment; use `""` plus `OAUTH2_PROXY_AUTHENTICATED_EMAILS_FILE` for an allowlist |
| `OAUTH2_PROXY_UPSTREAMS` | `static://202` | Traefik does the proxying; oauth2-proxy only answers `/oauth2/auth` |
| `OAUTH2_PROXY_REDIRECT_URL` | `https://<sub>.${DOMAIN}/oauth2/callback` | Must match the catalog |
| `OAUTH2_PROXY_COOKIE_DOMAINS`, `OAUTH2_PROXY_WHITELIST_DOMAINS` | `.${DOMAIN}` | Only for multi-host apps, so the cookie and the `rd` return URL work on the API host too |
| `forwardauth.address` | `http://quarantine-oauth2-proxy-<app>:4180/oauth2/auth` | Target the container name; a service alias would round-robin between PR sandboxes |

### Attach the middlewares to your routers

```yaml title="apps/first-party/myapp/compose.yaml (labels)"
- traefik.http.routers.myapp.middlewares=oauth2-errors-myapp,oauth2-auth-myapp
```

Order matters: `oauth2-errors-<app>` first (turns 401 into a redirect to
`/oauth2/sign_in`), `oauth2-auth-<app>` second. Give your catch-all `Host()`
router a priority below 100 so `/oauth2/*` reaches the proxy's own router
(Lazzaretto's frontend uses 10). For a separate API host, add a higher-priority
`Method(\`OPTIONS\`)` router without the middlewares, or CORS preflights fail
(see Lazzaretto's `-api-preflight` router).

### Identity contract for backends

If the backend needs to know who the user is:

- Set `OAUTH2_PROXY_SET_AUTHORIZATION_HEADER: "true"` and keep `Authorization`
  in `authResponseHeaders`. The backend then receives
  `Authorization: Bearer <id_token>`.
- Request scopes `openid email profile urn:zitadel:iam:user:resourceowner urn:zitadel:iam:org:projects:roles`
  (add `offline_access` for refresh).
- **Verify the JWT in the backend** (signature against
  `https://auth.<domain>/oauth/v2/keys`, issuer, expiry, audience). Do not trust
  forwarded headers alone.
- Read the issuer from an environment variable (`ZITADEL_ISSUER_URL` in
  Lazzaretto), never a literal.
- `idTokenUserinfoAssertion` must be on, or the ID token has no email or name.
  New applications get it; older ones need the Console toggle "User Info
  inside ID Token". For roles in the ID token, also enable "User Roles Inside
  ID Token" (see [Grant a role](/platform/guides/users/grant-a-role/)).
- Exclude the container healthcheck path from JWT checks; healthchecks never
  pass through Traefik.
- Keep a switch for local development without a proxy (Lazzaretto:
  `AUTH_MODE=required|off`).

Lazzaretto's backend (`backend/src/auth/` in
[QuarantineAl/lazzaretto](https://github.com/QuarantineAl/lazzaretto)) is the
reference implementation.

## Pattern 2: native OIDC

Point the app at `https://auth.${DOMAIN}` with `${OIDC_CLIENT_ID_<APP>}` and
`${OIDC_CLIENT_SECRET_<APP>}`, and use the callback path the app expects in
`oidc_redirect_uris` (Kujtime: `/api/auth/callback`; Vaultwarden:
`/identity/connect/oidc-signin`). No proxy block. Kujtime serves several city
hosts from one application by adding each city's callback with
`quarantine app add-redirect kujtime https://<city>-kujtime.<domain>/api/auth/callback`.

## Check it

```bash title="On the VM after quarantine start"
quarantine app list-redirects myapp
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://myapp.dev.quarantine.al/
# 302 https://auth.dev.quarantine.al/oauth/v2/authorize?... for a proxied app
```

## Who can sign in

The `quarantine-apps` project has no project-level role or grant check, so any
user of that environment's Zitadel can complete the OIDC flow for any app.
Restrict access in oauth2-proxy (allowlist) or in the app (roles). See
[Add a user](/platform/guides/users/add-a-user/).
