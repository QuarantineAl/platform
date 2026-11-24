---
title: quarantine app
description: Add and remove catalog apps, manage OIDC redirect URIs and project roles.
sidebar:
  order: 2
---

`quarantine app` has two halves:

- `add` / `remove` edit this environment's `manifest.yaml` (desired state).
- `add-redirect`, `remove-redirect`, `list-redirects`, `add-role`,
  `list-roles` act on the app's Zitadel application and the app's own
  Zitadel project (Lazzaretto's is `quarantine-apps`). These only accept apps whose catalog entry has
  `needs_oidc: true`.

Run on the VM. Every command acts on the VM's own environment.

| Command | Mutates | Takes env lock |
|---|---|---|
| `app add <name> [--version V]` | `manifest.yaml` | yes |
| `app remove <name>` | `manifest.yaml` | yes |
| `app add-redirect <name> <uri>` | Zitadel application | no (own per-application lock) |
| `app remove-redirect <name> <uri>` | Zitadel application | no |
| `app list-redirects <name> [--json]` | nothing | no |
| `app add-role <name> <role> [--display-name D] [--group G]` | Zitadel project | no |
| `app list-roles <name> [--json]` | nothing | no |

## app add

```text
quarantine app add <name> [--version V]
```

Adds a catalog app to `environments/<env>/manifest.yaml`, or updates its
`version` if it is already there. It does **not** start anything: run
`quarantine start` afterwards, and commit the manifest.

| Argument | Meaning |
|---|---|
| `<name>` | Catalog name (`^[a-z][a-z0-9-]*$`); must exist in `catalog.yaml` |
| `--version V` | Image tag exported as `<APP>_VERSION` (`[A-Za-z0-9._-]+`), e.g. `dev`, `prod`, a commit SHA. Omit to use the compose fragment's default. |

```bash title="Pin Lazzaretto on prod to an exact build (rollback), on prod-vm"
cd /opt/quarantine/repo
quarantine app add lazzaretto --version 288ec78058114ce5cfd9283241214aedc81d4f63
quarantine start
```

```text
[quarantine] 'lazzaretto' already in manifest — updated version to 288ec78058114ce5cfd9283241214aedc81d4f63
```

For a new entry the output is:

```text
[quarantine] added 'n8n' to environments/dev/manifest.yaml — run 'quarantine start' to apply
[quarantine] remember to git add/commit/push environments/dev/manifest.yaml
```

| Error | Fix |
|---|---|
| `'foo' is not in catalog.yaml — see docs/adding-an-app.md` | Add the app to the catalog first: [Add an app](/platform/guides/apps/add-an-app/) |
| `invalid --version '...'` | Only letters, digits, `.`, `_`, `-` |

:::caution
CI deploys run `app add <app> --version <env>` on every deploy, so a pinned
SHA in the manifest is overwritten by the next deploy of that app. Commit a
manual pin, or the next deploy's `git pull --ff-only` can conflict with it.
:::

## app remove

```text
quarantine app remove <name>
```

Deletes the app from the manifest. The next `quarantine start` **stops** its
containers (volumes and its Zitadel application are kept).

```bash title="On the VM"
quarantine app remove searxng
quarantine start
```

```text
[quarantine] removed 'searxng' from environments/dev/manifest.yaml — run 'quarantine start' to stop it
[quarantine] remember to git add/commit/push environments/dev/manifest.yaml
```

If the app is not in the manifest: `'searxng' is not in the manifest — nothing to do`.

## app add-redirect / app remove-redirect

```text
quarantine app add-redirect <name> <redirect_uri>
quarantine app remove-redirect <name> <redirect_uri>
```

Adds or removes one redirect URI (and its derived post-logout URI, the same
URL without `/oauth2/callback`) on the app's **existing** Zitadel application.
Used by CI for PR sandboxes and by `quarantine tenant add`/`purge`; you rarely
need it by hand. It never creates an application: `quarantine start` must have
provisioned the app first.

Zitadel can only replace an application's whole redirect list, so this is a
read-modify-write serialized with a per-application `flock`
(`.quarantine-locks/zitadel-app-<id>.lock`, 30 s wait). Adding a URI that is
already present, or removing one that is gone, is a no-op.

```bash title="Register a callback by hand (dev VM)"
quarantine app add-redirect lazzaretto https://pr-153-lazzaretto.dev.quarantine.al/oauth2/callback
```

```text
[quarantine] add-redirect: waiting for lock on Zitadel application 'lazzaretto' (<app-id>)
[quarantine] add-redirect: 'https://pr-153-lazzaretto.dev.quarantine.al/oauth2/callback' on 'lazzaretto' (<app-id>) already matches the desired state -- nothing to do
```

| Error | Fix |
|---|---|
| `'qualitech' is not a needs_oidc:true catalog app` | Only OIDC apps have an application |
| `no Zitadel application named 'x' found in project 'quarantine-apps'` | Add the app to the manifest and run `quarantine start` |
| `timed out waiting for the lock on Zitadel application` | Another add/remove is stuck; check running `quarantine` processes |

## app list-redirects

```text
quarantine app list-redirects <name> [--json]
```

Read-only. Lists every redirect URI on the app's application.

```bash title="dev VM"
quarantine app list-redirects lazzaretto
```

```text title="Output on dev, 2026-10-23"
[quarantine] using existing Zitadel project 'quarantine-apps' (<project-id>)
[quarantine] redirect URIs on 'lazzaretto' (<app-id>):
https://lazzaretto.dev.quarantine.al/oauth2/callback
https://pr-153-lazzaretto.dev.quarantine.al/oauth2/callback
https://pr-154-lazzaretto.dev.quarantine.al/oauth2/callback
https://pr-155-lazzaretto.dev.quarantine.al/oauth2/callback
```

On prod the same command lists the shared instance plus one callback per
tenant (`https://<tenant>-lazzaretto.quarantine.al/oauth2/callback`).

```bash title="JSON, dev VM"
quarantine app list-redirects delivery-note-ai --json
```

```json
{
  "app": "delivery-note-ai",
  "applicationId": "<app-id>",
  "redirectUris": [
    "https://delivery-note-ai.dev.quarantine.al/oauth2/callback"
  ],
  "postLogoutRedirectUris": [
    "https://delivery-note-ai.dev.quarantine.al"
  ]
}
```

## app add-role

```text
quarantine app add-role <name> <role> [--display-name D] [--group G]
```

Creates a role on the app's own Zitadel project. Prefer adding it to the
app's `zitadel_roles` in catalog.yaml, which `quarantine start` creates. Keys
keep the app prefix (`lazzaretto-admin`, `kujtime:admin`) because apps match
on the key. Role keys may
contain letters, digits, `.`, `_`, `:` and `-`. The display name defaults to
the key.

```bash title="Create the Lazzaretto admin role (once per environment)"
quarantine app add-role lazzaretto lazzaretto-admin --display-name "Lazzaretto admin"
```

```text
[quarantine] added role 'lazzaretto-admin' to project 'quarantine-apps' (<project-id>)
```

If it exists: `role 'lazzaretto-admin' already exists on project 'quarantine-apps' (...) — nothing to do`.

## app list-roles

```text
quarantine app list-roles <name> [--json]
```

Read-only. Lists every role on the app's project.

```text title="Output on dev, 2026-10-23"
[quarantine] using existing Zitadel project 'quarantine-apps' (<project-id>)
[quarantine] roles on project 'quarantine-apps' (<project-id>):
kujtime:admin
lazzaretto-admin
smoketest-role
smoketest-role-2
```

On prod on the same day: `agent:invoke` and `lazzaretto-admin`.

```json title="quarantine app list-roles lazzaretto --json (dev, trimmed)"
{
  "app": "lazzaretto",
  "projectId": "<project-id>",
  "roles": [
    { "key": "kujtime:admin", "displayName": "Kujtime platform admin", "group": "" },
    { "key": "lazzaretto-admin", "displayName": "lazzaretto-admin", "group": "" }
  ]
}
```

To give a role to someone, see [Grant a role](/platform/guides/users/grant-a-role/).
