---
title: Verify a user's email
description: Mark a Zitadel user's email as verified without SMTP, so oauth2-proxy-fronted apps accept them.
sidebar:
  order: 3
---

## Why it matters

Apps behind oauth2-proxy (Lazzaretto, delivery-note-ai, n8n, uptime-kuma)
reject an ID token whose `email_verified` claim is false. oauth2-proxy v7.15
only accepts unverified emails when started with
`--insecure-oidc-allow-unverified-email`
(`OAUTH2_PROXY_INSECURE_OIDC_ALLOW_UNVERIFIED_EMAIL`), and no instance on this
platform sets it. The person signs in to Zitadel successfully, then the app's
`/oauth2/callback` fails.

`quarantine user add` always creates the email **unverified** and asks Zitadel
to send a verification code. Zitadel has **no SMTP provider** on dev or prod,
so that code never arrives.

## When you need this

- The user was created with `--password-stdin` (no invite to redeem).
- An invite was never redeemed, and you do not want to send a new one.
- The address has no real mailbox (a shared or test account such as
  `tikappapi@dev.quarantine.al`).

Check first:

```bash
quarantine user show alice@example.com | grep emailVerified
```

`emailVerified: false` means you need the procedure below.

## Procedure

This is the exact procedure used on dev on 2026-10-23 for
`tikappapi@dev.quarantine.al`. It works on any environment because it reads
the environment name and domain from the VM's own config.

:::caution
It uses the platform's provisioner token, which is a full Zitadel
administrator. Run it only on the VM, never paste the token, and close the
shell when done.
:::

**1. Open a throwaway shell on the VM.** `lib/common.sh` helpers call `exit` on
error, so source them in a subshell, not your login shell.

```bash title="On the VM, as root"
cd /opt/quarantine/repo
bash
```

**2. Load the provisioner token and a request helper.**

```bash
source lib/common.sh
ENV="$(yq '.env' /opt/quarantine/quarantine.yaml)"
DOMAIN="$(yq '.domain' /opt/quarantine/quarantine.yaml)"
PLAIN="$(secrets_decrypt_to_tmpfs /opt/quarantine/repo "$ENV")"
ZITADEL_PAT="$(secrets_get "$PLAIN" '.core.zitadel.provisioner_pat')"
shred -u "$PLAIN"

# z METHOD PATH [JSON] — call Zitadel inside the edge network; the token goes over stdin
z(){ printf 'header = "Authorization: Bearer %s"\n' "$ZITADEL_PAT" \
  | docker run --rm -i --network edge curlimages/curl:8.11.1 -sS -K - -X "$1" \
      "http://zitadel-api:8080$2" -H "Host: auth.$DOMAIN" \
      -H "Content-Type: application/json" ${3:+--data "$3"}; }
```

**3. Find the user id.**

```bash
EMAIL=tikappapi@dev.quarantine.al
USER_ID="$(quarantine user show "$EMAIL" --json | yq -p json '.user.userId')"
echo "$USER_ID"
```

**4. Ask Zitadel for a new verification code, returned instead of emailed.**

```bash
z POST /v2/users/$USER_ID/email/resend '{"returnCode":{}}'
```

```json
{"details":{...},"verificationCode":"<code>"}
```

**5. Verify the email with that code.**

```bash
z POST /v2/users/$USER_ID/email/verify '{"verificationCode":"<code>"}'
```

A successful call returns a `details` object.

**6. Confirm, then clean up.**

```bash
quarantine user show "$EMAIL" | grep emailVerified    # emailVerified: true
unset ZITADEL_PAT
exit                                                   # leave the throwaway shell
```

The user can now sign in to oauth2-proxy-fronted apps. Existing failed sessions
need a fresh sign-in.

## Notes on the Zitadel endpoints

Checked against Zitadel v4.16.1 on dev:

- `POST /v2/users/{id}/email/resend` **works** with `{"returnCode":{}}`. This
  contradicts the header of `provisioners/zitadel.sh` and lazzaretto's
  `docs/TENANT_OPERATIONS.md`, which say no resend endpoint exists. The
  spellings that 404 are `/v2/users/{id}/email-code/resend` and
  `/v2/users/{id}/email/_resend`.
- `POST /v2/users/{id}/email` with the user's **current** address (the route
  those docs suggest) returns **400**, because nothing changes.
- There is no `quarantine user verify-email` command; this procedure is the
  supported path until SMTP is configured.
