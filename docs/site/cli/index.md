---
title: The quarantine CLI
description: What the quarantine command is, where it runs, how it handles secrets, and an overview of every command group.
sidebar:
  order: 0
---

`quarantine` is a single Bash script, [`bin/quarantine`](https://github.com/QuarantineAl/platform/blob/main/bin/quarantine),
that operates **one environment on the machine it runs on**: it reads that
environment's manifest and encrypted secrets, drives Docker Compose against the
local Docker daemon, and calls the local Zitadel through the Docker network.
It has no remote mode and no `--env` flag.

## Where it runs

On each VM, as root:

| | dev | prod |
|---|---|---|
| Host | `dev-vm` | `prod-vm` |
| Binary | `/usr/local/bin/quarantine` (symlink into the repo) | same |
| Repository | `/opt/quarantine/repo` (on `main`) | same |
| Config | `/opt/quarantine/quarantine.yaml` | same |
| Acts on | environment `dev`, domain `dev.quarantine.al` | environment `prod`, domain `quarantine.al` |

```bash title="Open a shell on the dev VM (from your laptop)"
ssh dev-vm          # host alias from your SSH config; see /start-here/environments/
sudo -i             # only if you did not log in as root
quarantine version
```

The config file decides which environment a command touches:

```yaml title="/opt/quarantine/quarantine.yaml (dev)"
repo: /opt/quarantine/repo
env: dev
domain: dev.quarantine.al
email: <admin email>
```

Set `QUARANTINE_CONFIG_FILE` to point at a different config. CI does this
explicitly (`QUARANTINE_CONFIG_FILE=/opt/quarantine/quarantine.yaml`) because
the runner container mounts `/opt/quarantine` at the same path.

:::caution[Not a laptop tool]
The CLI needs the environment's age key (`/opt/quarantine/keys/age-<env>.txt`),
the running Zitadel container and the local Docker daemon. None of these exist
on a laptop, and the age key must not be copied off the VM. To use the CLI,
SSH to the VM. `install.sh` is for provisioning a new Debian/Ubuntu **host**;
see [Stand up a new environment](/platform/guides/environments/new-environment/).
:::

## Requirements

`bin/quarantine` checks for these on every run and stops with
`missing required command(s): ...` if any is absent: Bash 4.4 or newer,
`docker` with the Compose v2 plugin, `yq` (mikefarah/yq v4, **not** the Python
`yq` that Debian's apt installs), `sops`, `age-keygen`, `curl`, `git` and
`flock`. `install.sh` installs pinned, checksum-verified `sops` 3.13.3 and `yq`
4.53.3, plus `age` from apt.

## How secrets are handled

Each command that needs secrets:

1. Decrypts `environments/<env>/secrets.sops.yaml` with
   `SOPS_AGE_KEY_FILE=/opt/quarantine/keys/age-<env>.txt` into a 0600 file on
   tmpfs (`/dev/shm/quarantine-secrets.XXXXXX`).
2. Passes that file's path to the provisioner it calls.
3. Shreds it when the process exits.

Passwords and tokens are never put on a command line: the Zitadel PAT is fed
to `curl` on stdin (`curl -K -`), and `user add --password-stdin` reads the
password from stdin.

Commands that *generate* a secret (a first-run app key, a machine user's
client secret, a tenant's credentials key) write it back into
`secrets.sops.yaml` and print a reminder. That file is tracked in git, so
commit it. See [Secrets](/platform/guides/secrets/).

## Conventions

- **Idempotent.** Re-running a command converges instead of failing:
  `user add` for an existing email does nothing, `app add-role` for an
  existing role does nothing, `start` twice changes nothing.
- **Locks.** Commands that rewrite `manifest.yaml` or `secrets.sops.yaml`
  (`init`, `start`, `app add`, `app remove`, `destroy`, `machine add`/`remove`/`onboard`,
  `tenant add`/`purge`) take a non-blocking `flock` on
  `/opt/quarantine/repo/.quarantine-locks/<env>.lock`. If another one is
  running you get
  `another quarantine operation is already running for environment 'dev'`;
  wait and retry. Read-only commands and the `user` commands take no lock.
- **Output.** Log lines go to stderr prefixed `[quarantine]`, warnings
  `[quarantine] WARN:`, errors `[quarantine] ERROR:` (exit code 1). Data (lists,
  `--json`) goes to stdout, so `--json` output pipes cleanly into `jq`.
- **No git operations.** Commands edit tracked files but never commit or push.
- **The curl image.** Every Zitadel-backed command runs
  `docker run --rm curlimages/curl:8.11.1`. The first time on a host, Docker
  prints `Unable to find image 'curlimages/curl:8.11.1' locally` and pull
  progress before the real output. That is harmless.

## Command overview

| Group | Commands | Page |
|---|---|---|
| Lifecycle | `init`, `start`, `status`, `version`, `upgrade`, `destroy` | [Lifecycle](/platform/cli/lifecycle/) |
| Apps | `app add`, `app remove`, `app add-redirect`, `app remove-redirect`, `app list-redirects`, `app add-role`, `app list-roles` | [app](/platform/cli/app/) |
| People | `user add`, `user list`, `user show`, `user invite`, `user grant`, `user revoke`, `user remove` | [user](/platform/cli/user/) |
| Service accounts | `machine onboard`, `machine add`, `machine list`, `machine show`, `machine grant`, `machine revoke`, `machine remove` | [machine](/platform/cli/machine/) |
| Lazzaretto tenants | `tenant onboard`, `tenant add`, `tenant list`, `tenant show`, `tenant start`/`stop`/`restart`, `tenant logs`, `tenant upgrade`, `tenant upgrade-all`, `tenant remove`, `tenant purge`, `tenant member add`/`remove`/`list` | [tenant](/platform/cli/tenant/) |

`quarantine help` (or `-h`, `--help`, or no argument) prints the built-in usage;
it is reproduced verbatim at [CLI reference](/platform/reference/cli/).
`quarantine init --help` prints init's own options.

## Common errors

| Error | Cause | Fix |
|---|---|---|
| `no config at /opt/quarantine/quarantine.yaml — run 'quarantine init' first` | Not on a VM, or not root (the file is 0600 root) | SSH to the VM and become root |
| `age key not found for environment 'dev': /opt/quarantine/keys/age-dev.txt` | Running somewhere without the key | Run on the VM |
| `failed to decrypt secrets for 'dev' (check age key at ...)` | Key does not match the file's recipient | See [Secrets](/platform/guides/secrets/) |
| `zitadel-api container not running: quarantine-zitadel-api` | Zitadel is down | `quarantine status`, then `quarantine start` |
| `unknown 'user' subcommand: frob` | Typo; usage is printed first | Check the group page |
