---
title: Self sign-up
description: Who can make their own Zitadel account, what that account opens, and how to turn sign-up on or off.
sidebar:
  order: 6
---

## What it is

Zitadel's login page can show a **Register** button. An app can also open
the sign-up form directly by adding `prompt=create` to its login request
(Wishora's "Sign up" button does this).

It is one switch for the whole Zitadel instance: the instance's default
login policy, field `allowRegister`. The `quarantine` organisation uses the
default policy, so there is nothing to set per org.

| Environment | Sign-up | Since |
|---|---|---|
| dev | on | always |
| prod | off | 2026-11-24, while every app got its own role check |

## What a new account can open

Each app has its own Zitadel project. Every project has the role check on
(no role in the project, no login), except Wishora's. So an account someone
made themselves opens **only Wishora**. Anything else needs an admin:

- An app: `quarantine user grant <email> <app> <app>:access`. See
  [Grant a role](/platform/guides/users/grant-a-role/).
- Lazzaretto: a Lazzaretto role plus `quarantine staff add`, or tenant
  membership. See [Add a user](/platform/guides/users/add-a-user/).

To make a new app open to anyone with an account, set
`zitadel_role_check: false` on its catalog entry (only do this when the app
decides access itself). See [Add OIDC to an app](/platform/guides/apps/add-oidc/).

## No email server yet

Zitadel has no SMTP provider on dev or prod. For self sign-up that means:

- The email is **not verified**. Zitadel still lets the person log in, and
  apps that talk to Zitadel themselves (Wishora) work. Apps behind
  oauth2-proxy refuse unverified emails, so before granting such an app to
  a self-made account, [verify the email](/platform/guides/users/verify-email/).
- Anyone can type any address. Before granting a role by email, make sure
  the account really belongs to that person (ask them, or check
  `quarantine user show <email>` for when it was created).
- "Forgot password" emails never arrive. Reset the password by hand in the
  Console (Users → the person → set password).

## Check whether sign-up is on

On the VM, in a throwaway shell with the `z` helper from
[Verify a user's email](/platform/guides/users/verify-email/) (steps 1–2):

```bash
z GET /admin/v1/policies/login | yq -p json '.policy.allowRegister'     # instance default
z GET /management/v1/policies/login | yq -p json '.policy.isDefault'    # true: the org uses it
```

`true` means on. `null` or `false` means off.

## Turn sign-up on or off

Changing it is the owner's call, and on prod it opens the door to anyone on
the internet. The PUT replaces the whole policy, so send back everything
you read with only `allowRegister` changed, then compare:

```bash
before="$(z GET /admin/v1/policies/login | yq -p json -o json '.policy')"
body="$(printf '%s' "$before" | yq -p json -o json -I0 \
  'del(.details, .isDefault, .secondFactors, .multiFactors, .idps) | .allowRegister = true')"
z PUT /admin/v1/policies/login "$body"; echo
after="$(z GET /admin/v1/policies/login | yq -p json -o json '.policy')"
diff <(printf '%s' "$before" | yq -p json -o json 'del(.details)') \
     <(printf '%s' "$after"  | yq -p json -o json 'del(.details)')
```

The diff must show only `allowRegister`. Use `= false` to turn it off. It
takes effect at once; the login page shows or hides Register on the next
load.

There is no `quarantine` command for this yet.
