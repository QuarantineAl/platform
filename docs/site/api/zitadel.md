---
title: Zitadel API cookbook
description: Call the Zitadel API of an environment with curl - authentication, base URLs, and read-only recipes for users, memberships, grants, projects and OIDC.
sidebar:
  order: 1
---

Each environment has its own Zitadel v4.16.1 instance. The `quarantine` CLI
covers everyday user and role management; use the API directly for questions
the CLI does not answer (memberships, grants, raw user records) or for
debugging. Every recipe below was run read-only against dev on 2026-10-23.
IDs and emails in responses are replaced with placeholders.

## Base URLs

| From | Base URL | Notes |
|---|---|---|
| Anywhere (HTTPS) | `https://auth.dev.quarantine.al`, `https://auth.quarantine.al` | Traefik routes every path except `/` and `/ui/v2/login` to the API. `/api/<path>` also works (prefix stripped). |
| On the VM, inside Docker | `http://zitadel-api:8080` on the `edge` network | Must send `Host: auth.<domain>`, or Zitadel answers `Instance not found` |

The CLI always uses the in-network route.

## Authentication

Every API call needs `Authorization: Bearer <token>`. Without it:

```json
{"code":16,"message":"auth header missing"}
```

### The provisioner token (on the VM)

The CLI's own credential is the personal access token of the machine user
`quarantine-provisioner`, stored at `core.zitadel.provisioner_pat` in the
environment's secrets. It holds **IAM_OWNER and ORG_OWNER**: it can do
anything. Load it only on the VM, into a variable, inside a throwaway shell:

```bash title="VM, as root"
cd /opt/quarantine/repo
bash                                   # helpers may call exit; keep your login shell safe
source lib/common.sh
ENV="$(yq '.env' /opt/quarantine/quarantine.yaml)"
DOMAIN="$(yq '.domain' /opt/quarantine/quarantine.yaml)"
PLAIN="$(secrets_decrypt_to_tmpfs /opt/quarantine/repo "$ENV")"
ZITADEL_PAT="$(secrets_get "$PLAIN" '.core.zitadel.provisioner_pat')"
shred -u "$PLAIN"

# z METHOD PATH [JSON]: the token travels over stdin, never in argv
z(){ printf 'header = "Authorization: Bearer %s"\n' "$ZITADEL_PAT" \
  | docker run --rm -i --network edge curlimages/curl:8.11.1 -sS -K - -X "$1" \
      "http://zitadel-api:8080$2" -H "Host: auth.$DOMAIN" \
      -H "Content-Type: application/json" ${3:+--data "$3"}; }
```

Finish with `unset ZITADEL_PAT; exit`. Never echo the token or paste it
anywhere. All recipes below use `z`.

### Your own token (from a laptop)

Zitadel personal access tokens exist only for machine users. To call the API
from outside the VM, an administrator creates a dedicated machine user with
the narrowest role that works, in the Console (Users → Service Users →
Personal Access Tokens), and you export it:

```bash title="Laptop"
export BASE_URL=https://auth.dev.quarantine.al
export TOKEN='...'       # from your password manager
curl -sS -H "Authorization: Bearer $TOKEN" "$BASE_URL/auth/v1/users/me"
```

:::note
No such personal-token users exist today; everything is done on the VMs with
the provisioner token. For an app calling an API, use a client-credentials
machine user instead: [Machine users](/platform/guides/users/machine-users/).
:::

## Who am I

```bash
z GET /auth/v1/users/me
```

```json
{"user":{"id":"<provisioner-user-id>","details":{"resourceOwner":"<org-id>", "...":"..."},
 "state":"USER_STATE_ACTIVE","userName":"quarantine-provisioner",
 "machine":{"name":"quarantine provisioner (auto)"}}}
```

`details.resourceOwner` is the organisation id. The organisation itself:

```bash
z GET /management/v1/orgs/me
```

```json
{"org":{"id":"<org-id>","state":"ORG_STATE_ACTIVE","name":"quarantine","primaryDomain":"quarantine.auth.dev.quarantine.al"}}
```

## Search users

`POST /v2/users` with query filters. Combine `emailQuery`, `userNameQuery`,
`displayNameQuery` and `typeQuery` (`TYPE_HUMAN` / `TYPE_MACHINE`); set
`"query":{"limit":1000}` because the default page is small.

```bash title="Exact email"
z POST /v2/users '{"queries":[{"emailQuery":{"emailAddress":"tikappapi@dev.quarantine.al","method":"TEXT_QUERY_METHOD_EQUALS"}}]}'
```

```json
{
  "details": {"totalResult": "1"},
  "result": [{
    "userId": "<user-id>",
    "state": "USER_STATE_ACTIVE",
    "username": "tikappapi@dev.quarantine.al",
    "human": {
      "profile": {"givenName": "Tikappapi", "familyName": "User", "displayName": "Tikappapi User"},
      "email": {"email": "tikappapi@dev.quarantine.al", "isVerified": true},
      "passwordChangeRequired": true
    }
  }]
}
```

```bash title="All humans"
z POST /v2/users '{"queries":[{"typeQuery":{"type":"TYPE_HUMAN"}}],"query":{"limit":1000}}'
```

Keep the id for the next recipes:

```bash
USER_ID="$(z POST /v2/users '{"queries":[{"emailQuery":{"emailAddress":"tikappapi@dev.quarantine.al","method":"TEXT_QUERY_METHOD_EQUALS"}}]}' | yq -p json '.result[0].userId')"
```

## Get one user

```bash
z GET /v2/users/$USER_ID
```

Returns `{"details":{...},"user":{...}}` with the same user object as above.
Useful fields: `human.email.isVerified`, `human.passwordChangeRequired`,
`human.mfaInitSkipped`, `state`.

## List a user's memberships (admin rights)

Memberships are Zitadel administration roles on the instance, organisation or
a project; ordinary users have none.

```bash
z POST /management/v1/users/$USER_ID/memberships/_search '{}'
```

```json title="Ordinary user: no result array"
{"details":{"viewTimestamp":"2026-10-23T18:56:32.736985Z"}}
```

```json title="The bootstrap admin"
{"details":{"totalResult":"2"},"result":[
  {"userId":"<admin-id>","roles":["ORG_OWNER"],"displayName":"quarantine","orgId":"<org-id>"},
  {"userId":"<admin-id>","roles":["IAM_OWNER"],"displayName":"ZITADEL","iam":true}
]}
```

Instance-wide administrators: `z POST /admin/v1/members/_search '{}'` (on dev:
the admin user and `quarantine-provisioner` as `IAM_OWNER`, `login-client` as
`IAM_LOGIN_CLIENT`).

## List a user's project roles (grants)

Grants are read through the organisation-wide search with a `userIdQuery`
(the per-user search path returns 405):

```bash
z POST /management/v1/users/grants/_search "{\"queries\":[{\"userIdQuery\":{\"userId\":\"$USER_ID\"}}]}"
```

```json title="A user with a role"
{"details":{"totalResult":"1"},"result":[{
  "id":"<grant-id>","roleKeys":["kujtime:admin"],"state":"USER_GRANT_STATE_ACTIVE",
  "userId":"<user-id>","projectId":"<project-id>","projectName":"quarantine-apps",
  "userType":"TYPE_HUMAN","orgName":"quarantine"
}]}
```

No grants returns only `details`. To list everyone with a role on the project,
filter with `{"projectIdQuery":{"projectId":"<project-id>"}}` instead.

## Projects, roles and applications

```bash
z POST /zitadel.project.v2.ProjectService/ListProjects '{}'
```

```json
{"pagination":{"totalResult":"2"},"projects":[
  {"projectId":"<project-id>","organizationId":"<org-id>","name":"quarantine-apps","state":"PROJECT_STATE_ACTIVE","projectRoleAssertion":true},
  {"projectId":"<zitadel-project-id>","name":"ZITADEL","state":"PROJECT_STATE_ACTIVE"}
]}
```

`quarantine-apps` has no `projectRoleCheck` or `hasProjectCheck`.
`projectRoleAssertion` was `true` on dev and absent (false) on prod.

```bash title="Roles (same as quarantine app list-roles)"
z POST /management/v1/projects/<project-id>/roles/_search '{"query":{"limit":1000}}'
```

```bash title="Applications and their token settings"
z POST /zitadel.application.v2.ApplicationService/ListApplications \
  '{"filters":[{"projectIdFilter":{"projectId":"<project-id>"}}]}' \
  | yq -p json -o json '[.applications[] | {"name": .name,
      "redirectUris": .oidcConfiguration.redirectUris,
      "idTokenUserinfoAssertion": .oidcConfiguration.idTokenUserinfoAssertion,
      "idTokenRoleAssertion": .oidcConfiguration.idTokenRoleAssertion}]'
```

## SMTP

```bash
z POST /admin/v1/smtp/_search '{"query":{"limit":1}}'
```

`{"details":{...}}` with no `result` means no SMTP provider (both dev and prod
on 2026-10-23), so Zitadel cannot send invites or verification codes.

## OIDC endpoints (no token needed)

```bash title="Discovery, from anywhere"
curl -s https://auth.dev.quarantine.al/.well-known/openid-configuration
```

```json title="Trimmed"
{
  "issuer": "https://auth.dev.quarantine.al",
  "authorization_endpoint": "https://auth.dev.quarantine.al/oauth/v2/authorize",
  "token_endpoint": "https://auth.dev.quarantine.al/oauth/v2/token",
  "introspection_endpoint": "https://auth.dev.quarantine.al/oauth/v2/introspect",
  "userinfo_endpoint": "https://auth.dev.quarantine.al/oidc/v1/userinfo",
  "end_session_endpoint": "https://auth.dev.quarantine.al/oidc/v1/end_session",
  "jwks_uri": "https://auth.dev.quarantine.al/oauth/v2/keys",
  "grant_types_supported": ["authorization_code", "implicit", "refresh_token", "client_credentials",
    "urn:ietf:params:oauth:grant-type:jwt-bearer", "urn:ietf:params:oauth:grant-type:device_code"],
  "token_endpoint_auth_methods_supported": ["none", "client_secret_basic", "client_secret_post", "private_key_jwt"],
  "id_token_signing_alg_values_supported": ["EdDSA", "RS256", "RS384", "RS512", "ES256", "ES384", "ES512"]
}
```

```bash title="Signing keys (what backends verify JWTs against)"
curl -s https://auth.dev.quarantine.al/oauth/v2/keys
```

```bash title="Token endpoint (client credentials)"
curl -sS -X POST https://auth.dev.quarantine.al/oauth/v2/token \
  -u "$CLIENT_ID:$CLIENT_SECRET" -d grant_type=client_credentials \
  --data-urlencode "scope=openid urn:zitadel:iam:org:project:id:$PROJECT_ID:aud"
```

An unknown client returns `{"error":"invalid_client","error_description":"client not found"}`.
See [Machine users](/platform/guides/users/machine-users/).

```bash title="Userinfo, with a user's access token"
curl -s -H "Authorization: Bearer $TOKEN" https://auth.dev.quarantine.al/oidc/v1/userinfo
```

Without a token it answers `401`.

## Mutating calls

The CLI wraps the common writes (create/delete users, invites, grants, roles,
redirect URIs). The one write it does not wrap, verifying an email without
SMTP, is documented in [Verify a user's email](/platform/guides/users/verify-email/).
API paths the CLI relies on, confirmed live by its authors: `POST /v2/users/human`,
`DELETE /v2/users/{id}`, `POST /v2/users/{id}/invite_code` (underscored),
`POST /management/v1/users/{id}/grants`, `PUT`/`DELETE .../grants/{grantId}`,
`POST /management/v1/projects/{id}/roles`, and
`ApplicationService/UpdateApplication` (replaces the whole redirect list).
