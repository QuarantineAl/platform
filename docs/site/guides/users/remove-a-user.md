---
title: Remove a user
description: Offboard a person - tenant membership, roles, and the Zitadel identity.
sidebar:
  order: 4
---

Offboarding has up to three parts, in this order. Do it on every environment
where the person has an account (dev and prod are separate).

## 1. Remove tenant access (prod)

Find tenants that list them:

```bash title="prod VM"
quarantine tenant list
for t in $(quarantine tenant list --json | yq -p json '.tenants[].tenant'); do
  quarantine tenant member list "$t" | grep -qx 'alice@example.com' && echo "$t"
done
```

Remove them from each:

```bash
quarantine tenant member remove alice alice@example.com
```

They are refused at that tenant immediately, with no restart. Their data stays
in the tenant's database.

If the tenant was theirs alone, stop it too:

```bash
quarantine tenant remove alice            # containers removed, data kept
```

and only if the data must go:

:::danger
`quarantine tenant purge alice` deletes the tenant's volume (sessions,
profiles, stored credentials) for good. See [quarantine tenant](/platform/cli/tenant/#tenant-purge).
:::

## 2. Revoke roles (optional)

Deleting the user removes their grants too, so this only matters if you keep
the account:

```bash
quarantine user revoke alice@example.com lazzaretto lazzaretto-admin
```

## 3. Delete the Zitadel user

:::danger
This cannot be undone. Re-adding the email later creates a new user with a new
id, which apps may treat as a different person.
:::

```bash
quarantine user remove alice@example.com
```

```text
[quarantine] deleted Zitadel user 'alice@example.com' (<user-id>)
[quarantine] note: this removes the IDENTITY only. Any tenant allowlist still naming alice@example.com is now inert but should be cleaned up: quarantine tenant member remove <tenant> alice@example.com
```

## Check

```bash
quarantine user show alice@example.com     # ERROR: no Zitadel user with email 'alice@example.com'
```

Data the person created inside apps (Kujtime articles, Lazzaretto sessions on
the shared instance) is not touched by any of this; handle it in the app.
