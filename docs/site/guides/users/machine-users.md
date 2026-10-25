---
title: Machine users
description: Create a service account and use the OAuth2 client_credentials flow to call an API with a Zitadel token.
sidebar:
  order: 5
---

Use a machine user when software, not a person, calls an API: for example the
n8n workflow on prod that calls Lazzaretto's headless API as
`n8n-automation`. The machine user's **username is its `client_id`**, and the
CLI generates and stores its client secret.

## 1. Create it and grant a role

On the VM of the target environment:

```bash title="prod VM"
quarantine app add-role n8n agent:invoke --display-name "Invoke Lazzaretto headless tasks"   # if missing
quarantine machine onboard n8n-automation --grant n8n agent:invoke \
  --display-name "n8n workflow automation"
```

The client secret is printed once and stored in
`environments/<env>/secrets.sops.yaml` at `.machines["n8n-automation"].client_secret`.
Commit that file ([Secrets](/platform/guides/secrets/#committing-generated-secrets)).
To see the secret again later, without regenerating it:

```bash
quarantine machine show n8n-automation
```

Put it straight into the consuming system's credential store (n8n
Credentials, a CI secret); never into a page, ticket or chat.

## 2. Get an access token

Zitadel's token endpoint is `https://auth.<domain>/oauth/v2/token` and accepts
`client_secret_basic` or `client_secret_post`. The access token's audience is
set with the scope `urn:zitadel:iam:org:project:id:<project-id>:aud`, where
`<project-id>` is the `quarantine-apps` project id (`quarantine app list-roles
<app>` prints it; it is also `core.zitadel.project_id` in the secrets).

```bash title="Anywhere with HTTPS access (laptop, n8n, CI)"
export ISSUER=https://auth.quarantine.al
export CLIENT_ID=n8n-automation
export CLIENT_SECRET='...'          # from your secret store, not from this page
export PROJECT_ID='<project-id>'

curl -sS -X POST "$ISSUER/oauth/v2/token" \
  -u "$CLIENT_ID:$CLIENT_SECRET" \
  -d grant_type=client_credentials \
  --data-urlencode "scope=openid urn:zitadel:iam:org:project:id:${PROJECT_ID}:aud urn:zitadel:iam:org:projects:roles"
```

```json title="Response shape"
{
  "access_token": "eyJhbGciOiJSUzI1NiIs...",
  "token_type": "Bearer",
  "expires_in": <seconds>
}
```

The token is a JWT because the CLI creates machine users with access token type
JWT. Its `aud` contains the project id, and the role claim
`urn:zitadel:iam:org:project:<project-id>:roles` carries the granted roles.

:::caution
These docs did not mint a real token (it would require reading a live client
secret). The scope string follows Lazzaretto's `docs/headless-api.md` and
Zitadel's documentation; a wrong client id returns
`{"error":"invalid_client","error_description":"client not found"}` (checked on
dev).
:::

## 3. Call the API

```bash
export TOKEN="$(curl -sS -X POST "$ISSUER/oauth/v2/token" -u "$CLIENT_ID:$CLIENT_SECRET" \
  -d grant_type=client_credentials \
  --data-urlencode "scope=openid urn:zitadel:iam:org:project:id:${PROJECT_ID}:aud urn:zitadel:iam:org:projects:roles" \
  | jq -r .access_token)"

curl -sS -H "Authorization: Bearer $TOKEN" "$BASE_URL/<endpoint>"
```

The receiving app verifies the JWT against Zitadel's JWKS
(`https://auth.<domain>/oauth/v2/keys`), the issuer, the audience (project id)
and the role. For Lazzaretto's headless API (`/api/v1/tasks`,
`/api/v1/machine/*`, role `agent:invoke`), see [Lazzaretto](/apps/lazzaretto/).

:::note
An app behind oauth2-proxy only sees a bearer token if its Traefik router lets
that path bypass forward-auth; oauth2-proxy expects a browser session cookie.
:::

## Rotating or removing

There is no rotate command. To replace a leaked secret, remove and re-add the
machine user (this changes its user id, so re-grant roles), then update every
consumer:

```bash
quarantine machine remove n8n-automation
quarantine machine onboard n8n-automation --grant n8n agent:invoke --display-name "n8n workflow automation"
```

After `machine remove` the user no longer exists, so `onboard` creates a new
user and overwrites the stored secret with the new one. Commit
`secrets.sops.yaml` afterwards.
