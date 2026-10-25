---
title: Add a user
description: Create a Zitadel user that can sign in to the apps of one environment, and hand over their invite.
sidebar:
  order: 1
---

This creates a person's account in **one** environment's Zitadel. Dev
(`auth.dev.quarantine.al`) and prod (`auth.quarantine.al`) are separate
instances: someone who needs both gets two accounts, one per VM.

Run everything on the VM of the target environment, as root.

## 1. Create the user

Preferred: let them set their own password with an invite.

```bash title="dev VM"
quarantine user add alice@example.com --given-name Alice --family-name Example --invite
```

Neither environment has an SMTP provider, so nothing is emailed. The command
prints the code and a redemption URL instead:

```text
[quarantine] created Zitadel user 'alice@example.com' (<user-id>)
[quarantine] WARN: this Zitadel instance has NO SMTP provider configured, so it cannot deliver mail.
[quarantine] WARN: Nothing was emailed. Configure one in the Console (Settings -> Notifications -> SMTP),
[quarantine] WARN: or relay this code to alice@example.com yourself:
[quarantine] WARN:   invite code for alice@example.com: 6J0SI2
[quarantine] WARN:   they redeem it at https://auth.dev.quarantine.al/ui/login/user/init?userID=<user-id>&code=6J0SI2
```

Send the URL to the person over a private channel. Opening it lets them set a
password. Lost code: `quarantine user invite alice@example.com` prints a new one.

### Alternative: set an initial password

Use this for shared or test accounts (this is how `tikappapi@dev.quarantine.al`
was created on 2026-10-23). The password is read from stdin, never from argv:

```bash title="dev VM"
read -rs PASSWORD      # type the password, press Enter
printf '%s\n' "$PASSWORD" | quarantine user add tikappapi@dev.quarantine.al \
  --given-name Tikappapi --family-name User --password-stdin
unset PASSWORD
```

The password is created with `changeRequired: true`, so Zitadel asks for a new
one at first login. The email stays **unverified**, and oauth2-proxy rejects
unverified emails, so continue with
[Verify a user's email](/platform/guides/users/verify-email/) before handing it
over. (An invited user verifies by redeeming the code.)

## 2. Check the result

```bash
quarantine user show alice@example.com
```

```text
userId: <user-id>
email: alice@example.com
emailVerified: true
...
state: USER_STATE_ACTIVE
```

`emailVerified: false` is expected until the invite is redeemed (or you run the
verify-email procedure).

## 3. What the user can now reach

An account on its own opens only apps that admit **any** signed-in user of that
environment, that is, apps whose oauth2-proxy sets
`OAUTH2_PROXY_EMAIL_DOMAINS: "*"` (checked in the running containers on
2026-10-23):

| Environment | Open to any signed-in user |
|---|---|
| dev | `lazzaretto.dev.quarantine.al` (shared instance and PR sandboxes), `delivery-note-ai.dev.quarantine.al` |
| prod | `lazzaretto.quarantine.al` (shared instance), `n8n.quarantine.al` (the editor, which then has n8n's own login) |

Everything else needs more:

- **A Lazzaretto tenant** (`<tenant>-lazzaretto.quarantine.al`): add the email
  to the tenant's allowlist, `quarantine tenant member add <tenant> <email>`,
  or give them their own tenant. See [quarantine tenant](/platform/cli/tenant/).
- **Admin rights inside an app** (Lazzaretto admin, Kujtime admin): a project
  role. See [Grant a role](/platform/guides/users/grant-a-role/).
- **Kujtime** signs people in itself; what a signed-in user can do there is
  up to the app.
- **Portainer** has its own accounts and does not use Zitadel.

## 4. The user is not a Zitadel admin

`user add` creates a plain user: no instance (IAM), organisation or project
memberships, so they cannot open the Zitadel Console's admin views or change
anything. To confirm, list their memberships with the provisioner token (see
the [Zitadel API cookbook](/platform/api/zitadel/) for the `z` helper):

```bash title="dev VM, after setting up z and USER_ID"
z POST /management/v1/users/$USER_ID/memberships/_search '{}'
```

```json title="No memberships: there is no result array"
{"details":{"viewTimestamp":"2026-10-23T18:56:32.736985Z"}}
```

An administrator, by contrast, shows `"roles":["ORG_OWNER"]` and
`"roles":["IAM_OWNER"]` entries.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `already exists (...) — nothing to do` | The account exists; use `user invite` for a new code |
| Zitadel login succeeds but the app's `/oauth2/callback` shows an error page | [Verify a user's email](/platform/guides/users/verify-email/) |
| Login works, then 403 at a tenant URL | Not in the tenant's allowlist |
| "User could not be found" on prod | The account was created on dev; create it on prod too |
