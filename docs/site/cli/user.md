---
title: quarantine user
description: Create, list, inspect, invite, grant roles to and remove Zitadel human users.
sidebar:
  order: 3
---

`quarantine user` manages **human** Zitadel users in the VM's own environment.
A dev user and a prod user are different accounts in different Zitadel
instances.

Every subcommand takes an **email** and resolves it to a Zitadel user id
itself (exact match on the email address). None of them takes the environment
lock or writes anything to the repository.

| Command | Mutates |
|---|---|
| `user add <email> [--given-name G] [--family-name F] [--invite] [--password-stdin]` | creates a user |
| `user list [--query S] [--json]` | nothing |
| `user show <email> [--json]` | nothing |
| `user invite <email>` | issues a new invite code |
| `user grant <email> <app> <role>` | adds a project role |
| `user revoke <email> <app> <role>` | removes a project role |
| `user remove <email>` | **deletes the user** |

An identity alone gives access only to apps that admit any signed-in user.
Lazzaretto tenants also need allowlist membership
([`quarantine tenant`](/platform/cli/tenant/)), and in-app admin rights need a
role grant. See [Add a user](/platform/guides/users/add-a-user/) for the whole
procedure.

## user add

```text
quarantine user add <email> [--given-name G] [--family-name F] [--invite] [--password-stdin]
```

Creates a human user whose username and email are `<email>`. If a user with
that email exists, it prints `already exists (...) — nothing to do` and exits 0
without changing the profile.

| Flag | Meaning |
|---|---|
| `--given-name G`, `--family-name F` | Profile names. Both default to the part of the email before `@`. |
| `--invite` | After creating, issue an invite so the person sets their own password. Preferred. |
| `--password-stdin` | Read an initial password from stdin. The user must change it at first login (`changeRequired: true`). |

`--password VALUE` is refused on purpose (argv is visible to other processes).
The email is created **unverified**; Zitadel is asked to send a verification
code, which it cannot do without SMTP.

:::caution
Pass `--invite` or `--password-stdin`. Without either, the user exists with no
password and no code; fix it with `quarantine user invite <email>`.
:::

```bash title="Preferred: invite (dev VM)"
quarantine user add alice@example.com --given-name Alice --family-name Example --invite
```

Neither environment has an SMTP provider, so the invite is printed for you to
hand over:

```text
[quarantine] created Zitadel user 'alice@example.com' (<user-id>)
[quarantine] WARN: this Zitadel instance has NO SMTP provider configured, so it cannot deliver mail.
[quarantine] WARN: Nothing was emailed. Configure one in the Console (Settings -> Notifications -> SMTP),
[quarantine] WARN: or relay this code to alice@example.com yourself:
[quarantine] WARN:   invite code for alice@example.com: 6J0SI2
[quarantine] WARN:   they redeem it at https://auth.dev.quarantine.al/ui/login/user/init?userID=<user-id>&code=6J0SI2
```

```bash title="With an initial password (dev VM)"
read -rs PASSWORD          # type it; nothing is echoed
printf '%s\n' "$PASSWORD" | quarantine user add alice@example.com \
  --given-name Alice --family-name Example --password-stdin
unset PASSWORD
```

A user created this way has an unverified email and is rejected by
oauth2-proxy until it is verified: see
[Verify a user's email](/platform/guides/users/verify-email/).

| Error | Fix |
|---|---|
| `invalid email '...'` | Use a plain address |
| `user-add --password-stdin: no password was read from stdin` | Pipe the password in |
| `invalid value '...': double quotes and backslashes are not allowed` | Remove `"` or `\` from names |

## user list

```text
quarantine user list [--query S] [--json]
```

Read-only. Every human user (machine users are excluded), sorted by email, as
`email<TAB>state<TAB>display name`. `--query` filters by display name
(case-insensitive substring). If Zitadel reports more matches than it returned,
a `TRUNCATED` warning is printed.

```text title="Output on dev, 2026-10-23 (emails replaced with placeholders)"
admin@example.com	USER_STATE_ACTIVE	Admin Admin
bob@example.com	USER_STATE_ACTIVE	Bob Example
kujtime-admin@example.com	USER_STATE_ACTIVE	Ermal Kujtime App
tikappapi@dev.quarantine.al	USER_STATE_ACTIVE	Tikappapi User
```

```bash title="JSON, filtered"
quarantine user list --query tika --json
```

```json
{
  "users": [
    {
      "userId": "<user-id>",
      "email": "tikappapi@dev.quarantine.al",
      "emailVerified": true,
      "username": "tikappapi@dev.quarantine.al",
      "givenName": "Tikappapi",
      "familyName": "User",
      "displayName": "Tikappapi User",
      "state": "USER_STATE_ACTIVE"
    }
  ]
}
```

## user show

```text
quarantine user show <email> [--json]
```

Read-only. One user, same fields as `--json` above.

```text title="Output on dev, 2026-10-23"
userId: <user-id>
email: tikappapi@dev.quarantine.al
emailVerified: true
username: tikappapi@dev.quarantine.al
givenName: Tikappapi
familyName: User
displayName: Tikappapi User
state: USER_STATE_ACTIVE
```

`emailVerified: false` means oauth2-proxy-fronted apps will reject the user.
Unknown email: `ERROR: no Zitadel user with email 'nobody@example.com'`.

## user invite

```text
quarantine user invite <email>
```

Issues a fresh invite for an existing user. With SMTP it resends the email;
without SMTP (today) it prints a new code and redemption URL, as in `user add
--invite`. Use it when a code was lost or expired, or the user was created
without `--invite`.

```bash
quarantine user invite alice@example.com
```

## user grant / user revoke

```text
quarantine user grant <email> <app> <role>
quarantine user revoke <email> <app> <role>
```

Adds or removes one role in the user's grant on the shared `quarantine-apps`
project. `<app>` must be a `needs_oidc` catalog app; as with
`app add-role`, it selects the project, not a per-app scope. The role must
already exist (`quarantine app list-roles <app>`).

A user has at most one grant on the project, holding a list of roles; revoking
the last role deletes the grant. Re-running is a no-op.

```bash title="dev VM"
quarantine user grant alice@example.com lazzaretto lazzaretto-admin
```

```text
[quarantine] using existing Zitadel project 'quarantine-apps' (<project-id>)
[quarantine] granted 'lazzaretto-admin' to alice@example.com on 'lazzaretto'
```

When the user already had another role, the message reads
`grantd 'lazzaretto-admin' for alice@example.com on 'lazzaretto'` (a cosmetic
typo in the CLI; the grant is correct).

```bash
quarantine user revoke alice@example.com lazzaretto lazzaretto-admin
```

```text
[quarantine] revoked 'lazzaretto-admin' from alice@example.com — that was the last role, so the grant itself was removed
```

| Error | Fix |
|---|---|
| `role 'x' does not exist on project 'quarantine-apps' — create it first: quarantine app add-role ...` | Create the role |
| `no Zitadel user with email '...' — create one first` | `quarantine user add` |

The user gets the role in new tokens only, so they need to sign in again. See
[Grant a role](/platform/guides/users/grant-a-role/).

## user remove

```text
quarantine user remove <email>
```

:::danger
Deletes the Zitadel user (`DELETE /v2/users/{id}`). Their sessions stop working
and the account cannot be restored; re-adding creates a new user with a new id.
:::

```bash
quarantine user remove alice@example.com
```

```text
[quarantine] deleted Zitadel user 'alice@example.com' (<user-id>)
[quarantine] note: this removes the IDENTITY only. Any tenant allowlist still naming alice@example.com is now inert but should be cleaned up: quarantine tenant member remove <tenant> alice@example.com
```

A missing user is a no-op. See [Remove a user](/platform/guides/users/remove-a-user/).
