---
title: Platform
description: What the QuarantineAl platform is, what runs on it, and where to start.
sidebar:
  order: 0
---

The platform is the shared infrastructure every QuarantineAl app runs on, plus
the `quarantine` CLI that operates it. It lives in
[QuarantineAl/platform](https://github.com/QuarantineAl/platform).

It is deliberately small: no Kubernetes, no PaaS, no scheduler. Each
environment is **one VM** running Docker Compose projects, described by files
in the repository:

- `catalog.yaml` declares every app the platform knows how to run.
- `environments/<env>/manifest.yaml` says which of those apps run in that
  environment, and at which version.
- `environments/<env>/secrets.sops.yaml` holds that environment's secrets,
  encrypted with an [age](https://github.com/FiloSottile/age) key that only
  lives on the VM.
- `quarantine start` reconciles the VM to match.

## Environments

| Environment | Host | Domain | Identity provider |
|---|---|---|---|
| dev | dev VM (`dev-vm`) | `dev.quarantine.al` | `https://auth.dev.quarantine.al` |
| prod | prod VM (`prod-vm`) | `quarantine.al` | `https://auth.quarantine.al` |

Each environment is fully separate: its own Traefik, Postgres, Zitadel,
age key and CI runner. **A Zitadel account on dev does not exist on prod**, and
the other way round. See [Environments](/start-here/environments/) for how to
reach the hosts.

## What runs where

Read from `environments/*/manifest.yaml` and checked against the running
containers on 2026-10-23. The full, always-current list is generated at
[App catalog](/platform/reference/catalog/).

| App | dev | prod | URL pattern | Sign-in |
|---|---|---|---|---|
| [Lazzaretto](/apps/lazzaretto/) | yes | yes, plus per-tenant instances | `lazzaretto.<domain>`, `<tenant>-lazzaretto.<domain>` | oauth2-proxy |
| [Kujtime](/apps/kujtime/) | yes | no | `kujtime.<domain>`, `<city>-kujtime.<domain>` | native OIDC in the app |
| [Qualitech](/apps/qualitech/) | yes | no | `qualitech.<domain>` | public site |
| [Delivery Note AI](/apps/delivery-note-ai/) | yes | no | `delivery-note-ai.<domain>` | oauth2-proxy |
| SearXNG | yes | yes | internal only (`http://quarantine-searxng:8080`) | none, not routed |
| n8n | no | yes | `n8n.<domain>` | oauth2-proxy |
| Portainer | no | yes | `portainer.<domain>` | Portainer's own login |

[Residences](/apps/residences/) has a catalog entry and is in dev's compose
graph, but it is not in dev's manifest and was not running on 2026-10-23.

## Start here

| I want to... | Go to |
|---|---|
| Understand how the pieces fit together | [Architecture](/platform/architecture/) |
| Learn the `quarantine` command | [The quarantine CLI](/platform/cli/) |
| Give someone an account | [Add a user](/platform/guides/users/add-a-user/) |
| Fix "email not verified" at sign-in | [Verify a user's email](/platform/guides/users/verify-email/) |
| Give someone admin rights in an app | [Grant a role](/platform/guides/users/grant-a-role/) |
| Let an automation call an API | [Machine users](/platform/guides/users/machine-users/) |
| Add a new app to the platform | [Add an app](/platform/guides/apps/add-an-app/) |
| Put an app behind Zitadel sign-in | [Add OIDC to an app](/platform/guides/apps/add-oidc/) |
| Understand how a merge reaches a VM | [Deploys](/platform/guides/apps/deploy/) |
| Get a preview URL for a pull request | [PR sandboxes](/platform/guides/pr-sandboxes/) |
| Read or change a secret | [Secrets](/platform/guides/secrets/) |
| Call the Zitadel API directly | [Zitadel API cookbook](/platform/api/zitadel/) |
| Stand up a new environment | [Stand up a new environment](/platform/guides/environments/new-environment/) |
| Size or grow a VM | [VM sizing](/platform/guides/environments/vm-sizing/) |

## Core services

Every environment runs these, whatever its manifest says:

| Service | Image | Role |
|---|---|---|
| Traefik | `traefik:v3.7.9` | TLS termination (Let's Encrypt wildcard certificate via Cloudflare DNS-01) and routing by Docker labels |
| Zitadel | `ghcr.io/zitadel/zitadel:v4.16.1` + `zitadel-login:v4.16.1` | OIDC identity provider at `auth.<domain>` |
| Postgres | `postgres:17.10-alpine` | Shared database, one database and role per consumer |
| oauth2-proxy | `quay.io/oauth2-proxy/oauth2-proxy:v7.15.3` | Forward-auth sidecar, one instance per app that needs it |
| GitHub Actions runner | `myoung34/github-runner:latest` | Self-hosted CI runner pool for that environment |

Observability (OpenTelemetry collector and SigNoz) and Redis (Valkey) are
defined but off: observability is opt-in per environment and disabled on
both, and Redis has no consumer yet.
