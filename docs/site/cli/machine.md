---
title: quarantine machine
description: Create and manage Zitadel machine users (service accounts) for the client_credentials flow.
sidebar:
  order: 4
---

`quarantine machine` manages Zitadel **machine users**: service accounts with
no person behind them, such as the n8n workflow that calls Lazzaretto's
headless API. A machine user's **username is its OAuth2 `client_id`**; the CLI
generates a client secret, prints it once, and stores it in the environment's
`secrets.sops.yaml` at `.machines["<username>"].client_secret`.

Machine users are not OIDC applications: there are no redirect URIs and no
catalog entry. To get a token, see [Machine users](/platform/guides/users/machine-users/).

| Command | Mutates | Env lock |
|---|---|---|
| `machine onboard <username> --grant <app> <role> [--display-name D]` | creates user + secret + grant | yes |
| `machine add <username> [--display-name D]` | creates user + secret | yes |
| `machine list [--query S] [--json]` | nothing | no |
| `machine show <username> [--json]` | nothing (prints the secret) | no |
| `machine grant <username> <app> <role>` | adds a project role | no |
| `machine revoke <username> <app> <role>` | removes a project role | no |
| `machine remove <username>` | **deletes the user** | yes |

Usernames may contain letters, digits, `.`, `_` and `-`.

## machine onboard

```text
quarantine machine onboard <username> --grant <app> <role> [--display-name D]
```

Runs `machine add` then `machine grant` in one call. `--grant` is required and
must be followed by two non-flag arguments; this is checked before anything is
created. The role must already exist (`quarantine app add-role`).

```bash title="How prod's n8n automation account was set up (prod VM)"
quarantine app add-role n8n agent:invoke --display-name "Invoke Lazzaretto headless tasks"
quarantine machine onboard n8n-automation --grant n8n agent:invoke \
  --display-name "n8n workflow automation"
```

```text title="Expected output (secret shown here as a placeholder)"
[quarantine] onboard 1/2: Zitadel machine identity for n8n-automation
[quarantine] created Zitadel machine user 'n8n-automation' (<user-id>)
[quarantine] Zitadel machine user 'n8n-automation' ready — client_id=n8n-automation
[quarantine] WARN: client_secret (shown once, now persisted to secrets.sops.yaml — retrieve again later with 'quarantine machine show n8n-automation'):
[quarantine] WARN:   <client-secret>
[quarantine] onboard 2/2: granting 'agent:invoke' on 'n8n'
[quarantine] granted 'agent:invoke' to n8n-automation on 'n8n'
```

Then commit `environments/<env>/secrets.sops.yaml` (it now holds the secret).

## machine add

```text
quarantine machine add <username> [--display-name D]
```

Creates the machine user (access token type JWT, description
`quarantine-managed automation account`), generates a client secret, stores
it, and prints it. The display name defaults to the username.

Idempotent: if the user exists and a secret is stored, it does nothing. If the
user exists but no secret is stored (an interrupted earlier run), it generates
a new secret.

## machine list

```text
quarantine machine list [--query S] [--json]
```

Read-only. `username<TAB>state<TAB>display name`. The two bootstrap accounts
always appear.

```text title="Output on prod, 2026-10-23"
login-client	USER_STATE_ACTIVE	quarantine login-client (auto)
n8n-automation	USER_STATE_ACTIVE	n8n workflow automation
quarantine-provisioner	USER_STATE_ACTIVE	quarantine provisioner (auto)
```

`--query` reuses the human display-name filter; it is not confirmed to match
machine names.

## machine show

```text
quarantine machine show <username> [--json]
```

Re-displays the stored client secret **without regenerating it** (regenerating
would break whatever credential already uses the old one).

:::caution
This prints a live credential to your terminal (`clientSecret:` on stderr, or
the `clientSecret` field with `--json`). Do not paste the output anywhere.
:::

```text title="Output shape"
userId: <user-id>
username: n8n-automation
displayName: n8n workflow automation
description: quarantine-managed automation account
state: USER_STATE_ACTIVE
[quarantine] clientSecret: <client-secret>
```

For a machine user created outside the CLI (e.g. `quarantine-provisioner`) it
prints `<none persisted — was this user created outside machine-add?>`.

## machine grant / machine revoke

```text
quarantine machine grant <username> <app> <role>
quarantine machine revoke <username> <app> <role>
```

Same behaviour as [`user grant`/`user revoke`](/platform/cli/user/#user-grant--user-revoke),
keyed by username.

```bash
quarantine machine grant n8n-automation n8n agent:invoke
```

## machine remove

```text
quarantine machine remove <username>
```

:::danger
Deletes the machine user. Every token and integration using it stops working.
:::

```text
[quarantine] deleted Zitadel machine user 'n8n-automation' (<user-id>)
[quarantine] note: this removes the IDENTITY only. secrets.sops.yaml still carries its now-orphaned client secret at .machines["n8n-automation"].client_secret — harmless ...
```

Remove the orphaned key with `sops` if you want the file tidy
([Secrets](/platform/guides/secrets/)).

:::note
The source marks the `machine-*` modes as not confirmed end to end against a
live instance when written. `n8n-automation` exists on prod and is in use, but
these docs did not re-run `machine add`.
:::
