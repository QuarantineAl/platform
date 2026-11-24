---
title: quarantine signup
description: Read or flip Zitadel self sign-up (the Register button on the login page).
sidebar:
  order: 7
---

Self sign-up lets anyone make their own Zitadel account from the login page.
It is **one switch for the whole Zitadel instance** (the default login
policy's `allowRegister`), not per app. An account someone made themselves
opens only Wishora; every other app still needs a role. See
[Self sign-up](/platform/guides/users/self-sign-up/) for what that means.

| Command | Mutates |
|---|---|
| `signup status` | nothing |
| `signup on` | turns sign-up on |
| `signup off` | turns sign-up off |

```bash title="dev VM"
quarantine signup status
```

```text title="Output"
sign-up: on
org uses the instance default: yes
```

The second line says whether the `quarantine` organisation follows the
instance default. If it says `no`, the org has its own login policy and the
switch does not affect it; `status` also prints the org's own setting.

## on / off

`on` and `off` read the policy, send it back with only `allowRegister`
changed, then read it again. If anything else changed, the command stops
with an error that shows the policy before and after; check it in the
Console. If sign-up is already in the state you asked for, nothing is sent.

On prod, `signup on` asks you to type `prod` first. Turning sign-up on in
prod is the owner's call: it lets anyone on the internet create an account.

The change takes effect at once; the login page shows or hides **Register**
on its next load. No lock is taken and no file is changed.
