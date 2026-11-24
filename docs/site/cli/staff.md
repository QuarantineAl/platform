---
title: quarantine staff
description: The staff allowlist - who may open the shared Lazzaretto instance.
sidebar:
  order: 6
---

Most apps are gated by Zitadel itself: each has its own Zitadel project that
requires a role to log in ([`quarantine user grant`](/platform/cli/user/)).
Lazzaretto can't be gated that way. The shared instance, its PR sandboxes and
every tenant share one Zitadel application, and tenant members hold
Lazzaretto roles. So the shared instance admits only the people on this
environment's **staff list**, the same way each tenant admits only its own
members ([`quarantine tenant`](/platform/cli/tenant/)).

To use the shared Lazzaretto a person needs both a Lazzaretto role and a
place on this list.

| Command | Mutates |
|---|---|
| `staff add <email>` | adds the email to the list |
| `staff remove <email>` | removes it |
| `staff list [--json]` | nothing |

```bash title="dev VM"
quarantine user grant alice@example.com lazzaretto lazzaretto-admin
quarantine staff add alice@example.com
quarantine staff list
quarantine staff remove alice@example.com
```

Changes apply without a restart: oauth2-proxy watches the file. Removing
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
never seen by the running proxy. Keep it mode `0644`; oauth2-proxy runs as a
non-root user and stops if it cannot read the file.

If the file is missing when the proxy starts, Docker refuses to start that
container, so the app is unreachable rather than open.
