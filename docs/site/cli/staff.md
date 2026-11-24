---
title: quarantine staff
description: The staff allowlist - who may open the internal apps behind oauth2-proxy.
sidebar:
  order: 6
---

Anyone can create an account on Zitadel's login page (Wishora needs public
sign-up), and every app shares one Zitadel organization and project. So being
signed in only proves someone has an account. The internal apps behind
oauth2-proxy admit only the people on this environment's **staff list**:

- the shared Lazzaretto instance and its PR sandboxes
- n8n
- docs
- bem
- delivery-note-ai
- uptime-kuma

Everyone else is refused with a 403 after signing in. Lazzaretto tenants use
their own allowlist instead ([`quarantine tenant`](/platform/cli/tenant/)).
Apps that sign people in themselves (Kujtime, Wishora) decide access in their
own code, and Portainer has its own accounts.

| Command | Mutates |
|---|---|
| `staff add <email>` | adds the email to the list |
| `staff remove <email>` | removes it |
| `staff list [--json]` | nothing |

```bash title="dev VM"
quarantine staff add alice@example.com
quarantine staff list
quarantine staff remove alice@example.com
```

Changes apply without a restart: each oauth2-proxy watches the file. Removing
someone refuses their next request. Emails are stored in lowercase, the way
oauth2-proxy compares them. `add` warns when no Zitadel user has that email
yet; create one with [`quarantine user add`](/platform/cli/user/).

## The file

The list is `/opt/quarantine/staff/authenticated-emails.txt` on the VM, one
email per line. It is outside the repository on purpose (it lists real
people's addresses), like the tenant allowlists. `quarantine start` creates
it empty if it is missing, and prints a warning, because an empty list lets
nobody in.

Edit it only through `quarantine staff`. If you must edit it by hand, rewrite
it in place (for example with an editor that does not replace the file):
Docker binds the file by inode, so a "write a new file and rename it" edit is
never seen by the running proxies. Keep it mode `0644`; oauth2-proxy runs as
a non-root user and stops if it cannot read the file.

If the file is missing when a proxy starts, Docker refuses to start that
container, so the app is unreachable rather than open.

## Why not `"*"`

An oauth2-proxy with `OAUTH2_PROXY_EMAIL_DOMAINS: "*"` admits every signed-in
user and silently ignores any allowlist it is given. Every internal block in
`infra/edge/oauth2-proxy/compose.yaml` therefore sets it to `""`. Do not add
a new internal app with `"*"`: copy one of those blocks, including the
`*staff-allowlist` volume.
