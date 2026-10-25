---
title: Grant a role
description: Create project roles and grant them to users, and how roles reach an app's tokens.
sidebar:
  order: 2
---

Apps that have their own admin features check a **Zitadel project role** in
the user's token, for example Lazzaretto checks `lazzaretto-admin` and Kujtime
checks `kujtime:admin`. Roles live on the single shared project
`quarantine-apps`, so a role is visible to every app; keys are prefixed with
the app name by convention.

Run on the VM of the environment where the user exists.

## 1. See which roles exist

```bash
quarantine app list-roles lazzaretto
```

```text title="dev, 2026-10-23"
[quarantine] roles on project 'quarantine-apps' (<project-id>), shared by every app in it:
kujtime:admin
lazzaretto-admin
smoketest-role
smoketest-role-2
```

On prod the same day: `agent:invoke`, `lazzaretto-admin`. Check the app's own
docs for which key it looks for (for Lazzaretto, see [Lazzaretto](/apps/lazzaretto/);
for Kujtime, [Kujtime](/apps/kujtime/)).

## 2. Create the role if it is missing

Once per environment:

```bash
quarantine app add-role kujtime kujtime:admin --display-name "Kujtime platform admin"
```

`user grant` refuses a role that does not exist, so a typo cannot silently
create a claim nothing checks.

## 3. Grant it

```bash
quarantine user grant alice@example.com lazzaretto lazzaretto-admin
```

```text
[quarantine] granted 'lazzaretto-admin' to alice@example.com on 'lazzaretto'
```

The user has to **sign in again** (or wait for their session to refresh) to get
a token carrying the role.

To check what a user holds, use the grants search in the
[Zitadel API cookbook](/platform/api/zitadel/#list-a-users-project-roles-grants).

## 4. Revoke it

```bash
quarantine user revoke alice@example.com lazzaretto lazzaretto-admin
```

Revoking the last role deletes the user's grant entirely.

## How roles appear in tokens

- Apps request the scope `urn:zitadel:iam:org:projects:roles` (Lazzaretto's
  oauth2-proxy requests it), and Zitadel adds the claim
  `urn:zitadel:iam:org:project:<project-id>:roles`, an object keyed by role:

  ```json
  "urn:zitadel:iam:org:project:<project-id>:roles": {
    "lazzaretto-admin": { "<org-id>": "quarantine.auth.dev.quarantine.al" }
  }
  ```

- Whether roles are written into the **ID token** (which is what an app behind
  oauth2-proxy receives in `Authorization: Bearer`) is the application's "User
  Roles Inside ID Token" setting (`idTokenRoleAssertion`). On 2026-10-23 it was
  on for the `lazzaretto` and `kujtime` applications on dev and for
  `lazzaretto` on prod; it was off for `delivery-note-ai` and `n8n`.
- The project setting "Assert Roles on Authentication"
  (`projectRoleAssertion`) was **on on dev and off on prod**.
- New applications created by `quarantine start` get
  `idTokenUserinfoAssertion: true` (email and name inside the ID token) but no
  role-assertion setting. If an app's role check never matches, check these
  two settings in the Console (Project `quarantine-apps` → application →
  Token Settings) before changing code.

Machine users get roles the same way: `quarantine machine grant`. See
[Machine users](/platform/guides/users/machine-users/).
