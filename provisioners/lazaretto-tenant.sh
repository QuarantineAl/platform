#!/usr/bin/env bash
# provisioners/lazaretto-tenant.sh — one Lazaretto instance per TENANT.
#
# Not invoked directly by CI or by hand — `quarantine tenant ...`
# (bin/quarantine) is the operator-facing entry point and is what decrypts
# secrets and resolves DOMAIN before calling in here, exactly as
# provisioners/zitadel.sh is fronted by `quarantine app add-redirect`.
#
# WHAT A TENANT IS
#   A tenant is a trust boundary that holds one member by default and may hold
#   a small team. BETWEEN tenants the boundary is the container; INSIDE one it
#   is the app's existing ownerId row-scoping, unchanged — no tenantId column,
#   no app-side tenancy code. A tenant of one is just the degenerate case, so
#   the same image serves the shared dev instance and every tenant.
#
#   Adding a member to a tenant is therefore a TRUST DECISION, not a config
#   change: members share a container, so one member's coding agent can read
#   another's session workspaces, CLI OAuth tokens and the SQLite file itself.
#   See lazaretto's docs/PER_TENANT_CONTAINER_PLAN.md §3. People who should
#   not see each other's tokens get separate tenants — which is the default.
#
# THE TWO HALVES OF ONBOARDING
#   IDENTITY   — a Zitadel user (provisioners/zitadel.sh's user-* modes).
#   MEMBERSHIP — an entry in THIS tenant's oauth2-proxy allowlist, plus a
#                redirect URI on the shared Zitadel Application.
#   EMAIL is the join key and neither half implies the other: a Zitadel user
#   with no allowlist entry authenticates and is then 403'd at the edge, and
#   an allowlist entry naming nobody in Zitadel is inert. `member add` warns
#   when it writes the second without the first.
#
# Usage:
#   lazaretto-tenant.sh add     <repo_root> <env> <secrets> <tenant> --email <e>[,<e>...] [--version V] [--concurrency N]
#   lazaretto-tenant.sh list    <repo_root> <env> <secrets> [--json]
#   lazaretto-tenant.sh show    <repo_root> <env> <secrets> <tenant> [--json]
#   lazaretto-tenant.sh start|stop|restart|remove <repo_root> <env> <secrets> <tenant>
#   lazaretto-tenant.sh purge   <repo_root> <env> <secrets> <tenant> [--yes]
#   lazaretto-tenant.sh upgrade <repo_root> <env> <secrets> <tenant> [version]
#   lazaretto-tenant.sh upgrade-all <repo_root> <env> <secrets> [version]
#   lazaretto-tenant.sh logs    <repo_root> <env> <secrets> <tenant> [service...]
#   lazaretto-tenant.sh member-add|member-remove <repo_root> <env> <secrets> <tenant> <email>
#   lazaretto-tenant.sh member-list <repo_root> <env> <secrets> <tenant> [--json]
#
# DESIGN NOTES, each of which is a thing that bites if done the obvious way:
#
# * NO TENANT REGISTRY FILE. `list` and `show` derive live state from
#   `docker compose ls`/`docker inspect` on the quarantine-lazaretto-<tenant>
#   project names, unioned with the tenant directories on disk. A registry
#   would be a second source of truth and would drift the first time somebody
#   removed a stack by hand. tenant.conf beside the allowlist holds only
#   OPERATOR INPUTS that cannot be derived from anything (which image tag to
#   deploy, what concurrency to allow) and are needed to bring a torn-down
#   tenant back up; it is never consulted for state that Docker can answer.
#
# * ALLOWLISTS LIVE OUTSIDE THE REPO, at $QUARANTINE_TENANTS_DIR (default
#   /opt/quarantine/tenants), next to the age keys. They hold real email
#   addresses, and .gitignore's opening rule makes everything under
#   environments/<env>/ tracked by default — a tenant directory in there would
#   be committed unless somebody remembered an ignore entry.
#
# * THE ALLOWLIST IS REWRITTEN IN PLACE, never written-then-renamed. Docker
#   binds a single-file mount by inode, so a rename swaps the host's file out
#   from under the running container, which goes on reading the original
#   forever and never fires a watcher event. Verified both ways against
#   oauth2-proxy v7.15.3: in-place truncate+write reloads, rename does not.
#   This is why `member add` needs no restart, and why doing it "safely" with
#   a temp file would silently break exactly that property.
#
# * COMPOSE GOES THROUGH qcompose_scoped, not `docker compose`. A tenant is
#   its own Compose project assembled from just two fragments — the app and
#   its oauth2-proxy sidecar — and NOT from environments/<env>/compose.yaml,
#   which would start a duplicate Traefik/Postgres/Zitadel inside the tenant's
#   project. qcompose_scoped is the wrapper that allows that while still
#   pinning --project-name and --env-file (see lib/common.sh).
#
# * LAZARETTO_VERSION IS EXPORTED EXPLICITLY. Both images are pinned to
#   ${LAZARETTO_VERSION:-CHANGEME}, and that variable only reaches
#   environments/<env>/.env for apps in that environment's manifest. A tenant
#   is deliberately not in any manifest, so omitting the export deploys a
#   literal :CHANGEME tag.
#
# * OAUTH2_PROXY_EMAIL_DOMAINS IS EMPTIED. An allowlist alongside the default
#   "*" is a SILENT no-op — oauth2-proxy's validator ends with
#   `if allowAll { valid = true }`, discarding the allowlist result. Left as
#   "*", every tenant's allowlist would admit every authenticated user and
#   the container boundary would be the only separation left.
#
# * `add` IS NOT ATOMIC and does not pretend to be. Its steps are ordered so
#   only the last is expensive to undo, every step is individually idempotent
#   so the whole verb is safely re-runnable, and `purge` cleans up whatever a
#   half-finished `add` left behind — including a redirect URI registered
#   against a hostname with no backing service.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT_SELF="$(cd -P "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT_SELF}/lib/common.sh"

require_bash4
require_cmd docker yq

APP_NAME="lazaretto"

# --- mode + argument parsing -------------------------------------------------
VERB="${1:-}"
case "$VERB" in
  add|list|show|start|stop|restart|remove|purge|upgrade|upgrade-all|logs| \
  member-add|member-remove|member-list) shift ;;
  *) die "usage: provisioners/lazaretto-tenant.sh <verb> <repo_root> <env> <secrets_file> [...]  (see this file's header)" ;;
esac

[[ $# -ge 3 ]] || die "usage: provisioners/lazaretto-tenant.sh ${VERB} <repo_root> <env> <plaintext_secrets_file> [...]"
repo_root="$1" env="$2" plaintext_file="$3"; shift 3
[[ -f "$plaintext_file" ]] || die "plaintext secrets file not found: $plaintext_file"

: "${DOMAIN:?DOMAIN must be set (inherited from load_config in bin/quarantine)}"
export QUARANTINE_REPO="${QUARANTINE_REPO:-$repo_root}"

tenant="" want_json=false want_yes=false version_in="" concurrency_in="" emails_in="" member_email=""
declare -a passthrough=()

# Every verb except list/upgrade-all takes <tenant> first.
case "$VERB" in
  list|upgrade-all) : ;;
  *) [[ $# -ge 1 ]] || die "${VERB}: missing <tenant>"; tenant="$1"; shift ;;
esac

case "$VERB" in
  member-add|member-remove)
    [[ $# -ge 1 ]] || die "${VERB}: missing <email>"
    member_email="$1"; shift ;;
  upgrade)
    [[ $# -ge 1 ]] && { version_in="$1"; shift; } ;;
  upgrade-all)
    [[ $# -ge 1 ]] && { version_in="$1"; shift; } ;;
  logs)
    passthrough=("$@"); set -- ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) want_json=true; shift ;;
    --yes) want_yes=true; shift ;;
    --email) emails_in="${2:?--email requires a value}"; shift 2 ;;
    --version) version_in="${2:?--version requires a value}"; shift 2 ;;
    --concurrency) concurrency_in="${2:?--concurrency requires a value}"; shift 2 ;;
    *) die "unknown argument to ${VERB}: $1" ;;
  esac
done

# Validated for the same reason every other provisioner here validates its
# inputs: these become a Compose project name, a DNS label, and a filesystem
# path. A tenant name is also half of a public hostname, so the charset is the
# DNS-label one rather than merely "safe to interpolate".
if [[ -n "$tenant" ]]; then
  [[ "$tenant" =~ ^[a-z][a-z0-9-]*$ ]] \
    || die "invalid tenant '${tenant}': lowercase letters, digits, hyphens only, must start with a letter"
  (( ${#tenant} <= 40 )) || die "tenant name '${tenant}' is too long (max 40 chars — it prefixes a hostname label)"
fi
[[ -z "$version_in" || "$version_in" =~ ^[A-Za-z0-9._-]+$ ]] \
  || die "invalid version '${version_in}': letters, digits, dots, underscores, hyphens only"
[[ -z "$concurrency_in" || "$concurrency_in" =~ ^[1-9][0-9]*$ ]] \
  || die "invalid --concurrency '${concurrency_in}': must be a positive integer"

validate_email() {
  [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "invalid email '$1'"
}
[[ -n "$member_email" ]] && validate_email "$member_email"

# --- per-tenant paths and naming ---------------------------------------------
TENANTS_ROOT="${QUARANTINE_TENANTS_DIR}/${env}"
tenant_dir()      { printf '%s/%s' "$TENANTS_ROOT" "$1"; }
tenant_allowlist(){ printf '%s/%s/authenticated-emails.txt' "$TENANTS_ROOT" "$1"; }
tenant_conf()     { printf '%s/%s/tenant.conf' "$TENANTS_ROOT" "$1"; }
tenant_project()  { printf 'quarantine-lazaretto-%s' "$1"; }
tenant_subdomain(){ printf '%s-lazaretto' "$1"; }
tenant_url()      { printf 'https://%s-lazaretto.%s' "$1" "$DOMAIN"; }
tenant_callback() { printf 'https://%s-lazaretto.%s/oauth2/callback' "$1" "$DOMAIN"; }
tenant_backend()  { printf 'quarantine-%s-lazaretto-backend' "$1"; }

COMPOSE_APP="${repo_root}/apps/first-party/${APP_NAME}/compose.yaml"
COMPOSE_PROXY="${repo_root}/infra/edge/oauth2-proxy/compose.yaml"

# --- tenant.conf: operator inputs only (see the header) ----------------------
conf_get() {
  local t="$1" key="$2" file
  file="$(tenant_conf "$t")"
  [[ -f "$file" ]] || return 0
  # Deliberately parsed, not sourced: this file lives outside the repo and
  # sourcing it would execute whatever it contains.
  sed -n "s/^${key}=//p" "$file" | tail -n1
}

conf_write() {
  local t="$1" version="$2" concurrency="$3" file
  file="$(tenant_conf "$t")"
  install -m 600 /dev/null "${file}.new"
  {
    printf '# Written by provisioners/lazaretto-tenant.sh. Operator inputs only —\n'
    printf '# live state (running/stopped, deployed image) is read from Docker.\n'
    printf 'version=%s\n' "$version"
    printf 'concurrency=%s\n' "$concurrency"
  } > "${file}.new"
  mv "${file}.new" "$file"
}

# --- the allowlist -----------------------------------------------------------
# json_string_array — reads lines on stdin, prints a JSON array of strings.
# Hand-built rather than routed through a yq parser: the values are email
# addresses already validated on the way in (no quote or backslash can reach
# here), and every alternative involved coaxing a CSV/scalar parser into
# treating a one-column list as an array, which was both fragile and hard to
# read.
json_string_array() {
  local out="[" first=true line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$first" == true ]] || out+=","
    first=false
    out+="\"${line}\""
  done
  printf '%s]' "$out"
}

# read_members <tenant> — one email per line, comments and blanks dropped.
# oauth2-proxy parses this file as CSV (so `#` starts a comment) and lowercases
# every address on both load and lookup; matching that here keeps what an
# operator sees identical to what actually gets enforced.
read_members() {
  local file
  file="$(tenant_allowlist "$1")"
  [[ -f "$file" ]] || return 0
  sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$file" \
    | grep -v '^$' || true
}

# write_members <tenant> [email...] — TRUNCATE AND WRITE IN PLACE.
#
# `: >` keeps the inode, which is the whole point: Docker bound this exact
# inode into the running container, so a rename would leave the container
# reading the old file forever with no watcher event. One printf for the whole
# body, so the container sees complete content on the reload rather than a
# half-written list.
#
# PERMISSIONS ARE LOAD-BEARING, and get this wrong and the failure is
# spectacularly indirect. oauth2-proxy runs as uid 65532, not root, and
# LoadAuthenticatedEmailsFile calls logger.Fatalf — not a warning — when it
# cannot open the file. So a root-owned 0600 file inside a 0700 directory
# (the obvious "these are email addresses, lock them down" choice, and what
# this function did first) makes the sidecar exit at startup and crash-loop
# under restart: unless-stopped. Traefik then cannot see that container's
# labels, so the oauth2-auth-<sub> middleware the app's routers reference
# "does not exist", both routers are dropped, and the whole tenant answers
# 404 — with nothing in the 404 pointing at a file mode. Confirmed live,
# exactly that chain.
#
# 0644/0755 is also the right call on the merits: this is a list of email
# addresses, not credentials, and the directory sits under /opt/quarantine
# alongside the age keys, which keep their own restrictive modes.
write_members() {
  local t="$1"; shift
  local file dir
  dir="$(tenant_dir "$t")"; file="$(tenant_allowlist "$t")"
  mkdir -p "$dir"; chmod 755 "$dir"
  [[ -f "$file" ]] || install -m 644 /dev/null "$file"
  : > "$file"
  (( $# > 0 )) && printf '%s\n' "$@" >> "$file"
  chmod 644 "$file"
}

# --- per-tenant generated secrets, from catalog.yaml's own declaration -------
# Same mechanism generate_env_file uses for a manifest app, but resolved under
# .tenants[<tenant>] so each tenant gets its OWN key. Generate-once: re-minting
# LAZARETTO_CREDENTIALS_KEY would make every credential that tenant has stored
# permanently undecryptable, so an existing value is never replaced.
export_tenant_secrets() {
  local t="$1" count i key env_var generator path value
  count="$(yq eval "[.apps[] | select(.name == \"${APP_NAME}\") | .generated_secrets[]?] | length" "${repo_root}/catalog.yaml")"
  for (( i = 0; i < count; i++ )); do
    key="$(yq eval ".apps[] | select(.name == \"${APP_NAME}\") | .generated_secrets[${i}].key" "${repo_root}/catalog.yaml")"
    env_var="$(yq eval ".apps[] | select(.name == \"${APP_NAME}\") | .generated_secrets[${i}].env" "${repo_root}/catalog.yaml")"
    generator="$(yq eval ".apps[] | select(.name == \"${APP_NAME}\") | .generated_secrets[${i}].generator" "${repo_root}/catalog.yaml")"
    [[ -z "$key" || "$key" == "null" ]] && continue

    path=".tenants[\"${t}\"].${key}"
    value="$(secrets_get "$plaintext_file" "$path")"
    if [[ -z "$value" || "$value" == CHANGEME* ]]; then
      log "generating ${env_var} for tenant '${t}' (first run; persisted, never regenerated)"
      value="$(gen_secret "$generator")"
      [[ -n "$value" ]] || die "generator '${generator}' produced an empty value for ${path}"
      secrets_set "$repo_root" "$env" "$path" "$value"
      log "secrets.sops.yaml was updated — remember to git add/commit/push environments/${env}/secrets.sops.yaml"
    fi
    export "${env_var}=${value}"
  done
}

# --- bringing a tenant up ----------------------------------------------------
# Resource limits are per instance and scaled to the tenant, from measurements
# on the live dev host: an idle trio costs ~67 MiB and a concurrent agent turn
# ~250 MiB, so memory is ~= 250 MiB x concurrency + 200 MiB headroom.
# CLI_MAX_CONCURRENT matters most: the backend defaults it to 4 PER PROCESS, so
# twenty instances would allow eighty concurrent turns — roughly 20 GiB of
# unbounded demand against a host with no swap.
#
# tenant_up <tenant> [pull]
#
# `pull` re-fetches the image tag before recreating, and is passed ONLY by the
# upgrade verbs. Deliberately not the default: `start` after a host reboot must
# work from the local image cache, and making every bring-up depend on GHCR
# being reachable and authenticated would turn a network blip into a tenant
# that will not start. Conversely an upgrade without it is a silent no-op the
# moment builds stop happening on this same host — compose sees an unchanged
# local image ID for the tag and recreates nothing.
tenant_up() {
  local t="$1" pull="${2:-}" version concurrency
  version="$(conf_get "$t" version)"; version="${version:-$env}"
  concurrency="$(conf_get "$t" concurrency)"; concurrency="${concurrency:-2}"

  export SUBDOMAIN; SUBDOMAIN="$(tenant_subdomain "$t")"
  export DOMAIN
  export LAZARETTO_VERSION="$version"
  export LAZARETTO_ALLOWLIST_FILE; LAZARETTO_ALLOWLIST_FILE="$(tenant_allowlist "$t")"
  # Empty, not unset: this is what turns oauth2-proxy's allowAll off so the
  # allowlist is actually consulted. See the header.
  export LAZARETTO_EMAIL_DOMAINS=""
  export LAZARETTO_CLI_MAX_CONCURRENT="$concurrency"
  export LAZARETTO_MEM_LIMIT="$(( 250 * concurrency + 200 ))m"
  export LAZARETTO_PIDS_LIMIT=512
  export_tenant_secrets "$t"

  # --wait is what makes a fleet-wide rollout safe to automate: without it
  # `up -d` returns the moment containers are STARTED, so a backend that boots
  # and dies still looks like success and upgrade-all marches on through every
  # remaining tenant. With it, compose blocks on the backend's healthcheck and
  # exits non-zero if the container goes unhealthy or exits — which, under
  # `set -e`, stops the loop at the first casualty and leaves the rest of the
  # fleet on the image that still works.
  #
  # The timeout is generous against the backend's own healthcheck
  # (start_period 15s + 5 x interval 10s -> ~65s worst case before it is
  # declared unhealthy) so a slow-but-fine boot on a loaded host is never
  # mistaken for a failure.
  local -a up_args=(up -d --wait --wait-timeout 180)
  [[ "$pull" == pull ]] && up_args+=(--pull always)

  log "bringing up tenant '${t}' (project $(tenant_project "$t"), image tag ${version}, concurrency ${concurrency}, mem ${LAZARETTO_MEM_LIMIT}${pull:+, pulling})"
  qcompose_scoped "$(tenant_project "$t")" "$env" \
    -f "$COMPOSE_APP" -f "$COMPOSE_PROXY" \
    --profile "$APP_NAME" "${up_args[@]}"

  # Still checked separately even with --wait: the sidecar has no healthcheck,
  # so --wait only requires it to be RUNNING, and its specific failure (an
  # unreadable allowlist) deserves the pointed diagnostic below rather than a
  # generic compose timeout.
  assert_proxy_healthy "$t"
}

# assert_proxy_healthy <tenant> — the sidecar has no HEALTHCHECK (distroless,
# nothing to probe itself with), so `up -d` returns success even when it is
# already dying. It exits rather than warns on an unreadable allowlist, and a
# crash-looping sidecar takes the tenant's Traefik middleware down with it,
# leaving the whole hostname answering 404 with nothing to connect it back to
# the real cause. Checking the restart count here turns that into one clear
# error at the point of provisioning.
assert_proxy_healthy() {
  local t="$1" c status restarts waited=0
  c="quarantine-oauth2-proxy-$(tenant_subdomain "$t")"
  while (( waited < 15 )); do
    status="$(docker inspect --format '{{.State.Status}}' "$c" 2>/dev/null || echo missing)"
    restarts="$(docker inspect --format '{{.RestartCount}}' "$c" 2>/dev/null || echo 0)"
    if [[ "$status" == "running" ]] && (( restarts == 0 )); then
      return 0
    fi
    if [[ "$status" == "restarting" ]] || (( restarts > 0 )); then
      warn "tenant '${t}''s oauth2-proxy is crash-looping (status=${status}, restarts=${restarts}). Its last words:"
      docker logs --tail 5 "$c" 2>&1 | sed 's/^/    /' >&2
      die "tenant '${t}' came up but its access-control sidecar did not. Until it runs, Traefik has no oauth2-auth-$(tenant_subdomain "$t") middleware and the tenant's hostname answers 404. The usual cause is an allowlist the container's non-root uid cannot read: check $(tenant_allowlist "$t") is 0644 inside a traversable directory."
    fi
    sleep 3; waited=$(( waited + 3 ))
  done
  warn "tenant '${t}''s oauth2-proxy is still ${status} after ${waited}s — check: docker logs ${c}"
}

tenant_compose() {
  local t="$1"; shift
  export SUBDOMAIN; SUBDOMAIN="$(tenant_subdomain "$t")"
  export DOMAIN
  export LAZARETTO_ALLOWLIST_FILE; LAZARETTO_ALLOWLIST_FILE="$(tenant_allowlist "$t")"
  export LAZARETTO_EMAIL_DOMAINS=""
  local version; version="$(conf_get "$t" version)"; export LAZARETTO_VERSION="${version:-$env}"
  qcompose_scoped "$(tenant_project "$t")" "$env" \
    -f "$COMPOSE_APP" -f "$COMPOSE_PROXY" --profile "$APP_NAME" "$@"
}

# --- discovery: every tenant this environment knows about --------------------
# Union of the Compose projects that actually exist and the tenant directories
# on disk, so a tenant is visible whether it is running, stopped, or was only
# half-created by an interrupted `add`.
all_tenants() {
  {
    docker compose ls --all --format json 2>/dev/null \
      | yq -p json '.[].Name' 2>/dev/null \
      | sed -n 's/^quarantine-lazaretto-//p' || true
    [[ -d "$TENANTS_ROOT" ]] && find "$TENANTS_ROOT" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; || true
  } | sort -u | grep -v '^$' || true
}

tenant_status() {
  local t="$1" state
  state="$(docker inspect --format '{{.State.Status}}' "$(tenant_backend "$t")" 2>/dev/null || true)"
  case "$state" in
    running) printf 'running' ;;
    "")      printf 'absent' ;;
    *)       printf '%s' "$state" ;;
  esac
}

tenant_deployed_version() {
  local t="$1" image
  image="$(docker inspect --format '{{.Config.Image}}' "$(tenant_backend "$t")" 2>/dev/null || true)"
  if [[ -n "$image" ]]; then printf '%s' "${image##*:}"; else conf_get "$t" version; fi
}

# =============================================================================
# add — write the allowlist, register the redirect URI, bring the stack up.
#
# In that order because only the third is expensive to undo, and each step is
# individually idempotent so the whole verb is safely re-runnable after a
# failure part-way through.
# =============================================================================
if [[ "$VERB" == "add" ]]; then
  [[ -n "$emails_in" ]] || die "add: --email <address>[,<address>...] is required"
  declare -a members=()
  IFS=',' read -r -a members <<< "$emails_in"
  (( ${#members[@]} > 0 )) || die "add: --email produced no addresses"
  for m in "${members[@]}"; do validate_email "$m"; done

  version="${version_in:-$(conf_get "$tenant" version)}"; version="${version:-$env}"
  concurrency="${concurrency_in:-$(conf_get "$tenant" concurrency)}"; concurrency="${concurrency:-2}"

  log "step 1/3: allowlist for tenant '${tenant}' (${#members[@]} member(s))"
  write_members "$tenant" "${members[@]}"
  conf_write "$tenant" "$version" "$concurrency"

  log "step 2/3: redirect URI on the shared '${APP_NAME}' Application"
  "${repo_root}/bin/quarantine" app add-redirect "$APP_NAME" "$(tenant_callback "$tenant")"

  log "step 3/3: instance"
  tenant_up "$tenant"

  log "tenant '${tenant}' is up at $(tenant_url "$tenant")"
  for m in "${members[@]}"; do
    if [[ -z "$("${repo_root}/provisioners/zitadel.sh" user-show "$repo_root" "$env" "$plaintext_file" "$m" --json 2>/dev/null || true)" ]]; then
      warn "no Zitadel user exists for ${m} — they can reach this tenant's allowlist but have no identity to log in with: quarantine user add ${m} --invite"
    fi
  done
  exit 0
fi

# =============================================================================
# member-add / member-remove / member-list
#
# oauth2-proxy watches the allowlist and reloads it, so neither write needs a
# restart. Verified against v7.15.3.
# =============================================================================
if [[ "$VERB" == "member-add" ]]; then
  [[ -d "$(tenant_dir "$tenant")" ]] || die "no tenant '${tenant}' in environment '${env}' — create it first: quarantine tenant add ${tenant} --email ${member_email}"
  declare -a current=()
  while IFS= read -r line; do [[ -n "$line" ]] && current+=("$line"); done < <(read_members "$tenant")
  # "${arr[@]}" with no ":-" fallback: this repo requires bash >= 4.4 (see
  # require_bash4), where an empty array expands to zero words under `set -u`.
  # A ":-" fallback would expand to one EMPTY word instead, which here would
  # mean writing a blank allowlist line or passing an empty argument along.
  for m in "${current[@]}"; do
    if [[ "$m" == "$member_email" ]]; then
      log "'${member_email}' is already a member of tenant '${tenant}' — nothing to do"
      exit 0
    fi
  done
  current+=("$member_email")
  write_members "$tenant" "${current[@]}"
  log "added '${member_email}' to tenant '${tenant}' (${#current[@]} member(s)) — no restart needed, oauth2-proxy reloads the file itself"
  if [[ -z "$("${repo_root}/provisioners/zitadel.sh" user-show "$repo_root" "$env" "$plaintext_file" "$member_email" --json 2>/dev/null || true)" ]]; then
    warn "no Zitadel user exists for ${member_email} — this allowlist entry is inert until one does: quarantine user add ${member_email} --invite"
  fi
  warn "adding a member is a TRUST decision: members share one container, so each can reach the others' session workspaces, CLI tokens and the SQLite file (PER_TENANT_CONTAINER_PLAN.md §3)"
  exit 0
fi

if [[ "$VERB" == "member-remove" ]]; then
  [[ -d "$(tenant_dir "$tenant")" ]] || die "no tenant '${tenant}' in environment '${env}'"
  declare -a kept=()
  found_member=false
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" == "$member_email" ]]; then found_member=true; continue; fi
    kept+=("$line")
  done < <(read_members "$tenant")
  if [[ "$found_member" != true ]]; then
    log "'${member_email}' is not a member of tenant '${tenant}' — nothing to do"
    exit 0
  fi
  write_members "$tenant" "${kept[@]}"
  log "removed '${member_email}' from tenant '${tenant}' — they are 403'd at the edge immediately, no restart needed"
  log "note: their rows stay in this tenant's database, owned by their User id and not visible to the remaining members"
  exit 0
fi

if [[ "$VERB" == "member-list" ]]; then
  [[ -d "$(tenant_dir "$tenant")" ]] || die "no tenant '${tenant}' in environment '${env}'"
  if [[ "$want_json" == true ]]; then
    printf '{"tenant":"%s","members":%s}\n' "$tenant" "$(read_members "$tenant" | json_string_array)"
  else
    read_members "$tenant"
  fi
  exit 0
fi

# =============================================================================
# list / show — derived state, no registry file.
# =============================================================================
if [[ "$VERB" == "list" ]]; then
  declare -a rows=()
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    status="$(tenant_status "$t")"
    deployed="$(tenant_deployed_version "$t")"
    count="$(read_members "$t" | wc -l | tr -d ' ')"
    rows+=("$(printf '{"tenant":"%s","url":"%s","status":"%s","version":"%s","members":%s,"project":"%s"}' \
      "$t" "$(tenant_url "$t")" "$status" "${deployed:-unknown}" "$count" "$(tenant_project "$t")")")
  done < <(all_tenants)

  if [[ "$want_json" == true ]]; then
    printf '{"tenants":[%s]}\n' "$(IFS=,; printf '%s' "${rows[*]}")"
  else
    if (( ${#rows[@]} == 0 )); then
      log "no tenants provisioned in environment '${env}'"
    else
      printf 'TENANT\tSTATUS\tVERSION\tMEMBERS\tURL\n'
      printf '{"tenants":[%s]}' "$(IFS=,; printf '%s' "${rows[*]}")" \
        | yq -p json '.tenants[] | .tenant + "\t" + .status + "\t" + .version + "\t" + (.members|tostring) + "\t" + .url'
    fi
  fi
  exit 0
fi

if [[ "$VERB" == "show" ]]; then
  status="$(tenant_status "$tenant")"
  # Known if it has state on disk OR containers in Docker — an interrupted
  # `add` leaves one without the other, and `show` is how an operator finds
  # that out.
  [[ -d "$(tenant_dir "$tenant")" || "$status" != "absent" ]] \
    || die "no tenant '${tenant}' in environment '${env}'"
  deployed="$(tenant_deployed_version "$tenant")"
  concurrency="$(conf_get "$tenant" concurrency)"; concurrency="${concurrency:-2}"
  volume="$(tenant_project "$tenant")_lazaretto-data"
  members_json="$(read_members "$tenant" | json_string_array)"

  body="$(printf '{"tenant":"%s","url":"%s","apiUrl":"https://%s-lazaretto-api.%s","status":"%s","version":"%s","project":"%s","volume":"%s","allowlist":"%s","concurrency":%s,"members":%s}' \
    "$tenant" "$(tenant_url "$tenant")" "$tenant" "$DOMAIN" "$status" "${deployed:-unknown}" \
    "$(tenant_project "$tenant")" "$volume" "$(tenant_allowlist "$tenant")" "$concurrency" "$members_json")"

  if [[ "$want_json" == true ]]; then
    printf '%s' "$body" | yq -p json -o json "{\"tenant\": .}"
  else
    printf '%s' "$body" | yq -p json 'to_entries | .[] | .key + ": " + (.value | tostring)'
  fi
  exit 0
fi

# =============================================================================
# lifecycle
# =============================================================================
case "$VERB" in
  start)
    [[ -d "$(tenant_dir "$tenant")" ]] || die "no tenant '${tenant}' in environment '${env}'"
    tenant_up "$tenant"; exit 0 ;;
  stop)
    tenant_compose "$tenant" stop; log "tenant '${tenant}' stopped (containers kept)"; exit 0 ;;
  restart)
    tenant_compose "$tenant" restart; log "tenant '${tenant}' restarted"; exit 0 ;;
  logs)
    tenant_compose "$tenant" logs "${passthrough[@]}"; exit 0 ;;
  remove)
    # `down` WITHOUT -v: the data volume and the allowlist both survive, so an
    # accidental offboard is recoverable with `tenant add`/`tenant start`. The
    # redirect URI is left registered for the same reason.
    tenant_compose "$tenant" down
    log "tenant '${tenant}' removed (containers gone; volume, allowlist and redirect URI preserved)"
    log "bring it back with: quarantine tenant start ${tenant}    |    delete its data with: quarantine tenant purge ${tenant}"
    exit 0 ;;
  upgrade)
    [[ -d "$(tenant_dir "$tenant")" ]] || die "no tenant '${tenant}' in environment '${env}'"
    version="${version_in:-$(conf_get "$tenant" version)}"; version="${version:-$env}"
    concurrency="$(conf_get "$tenant" concurrency)"; concurrency="${concurrency:-2}"
    conf_write "$tenant" "$version" "$concurrency"
    tenant_up "$tenant" pull
    log "tenant '${tenant}' now on image tag '${version}'"
    exit 0 ;;
  upgrade-all)
    # Per-tenant instances live outside `quarantine start`'s reconciliation
    # loop — nothing else will ever pick a new version up for them.
    #
    # Sequential and fail-fast, by way of `set -e` plus tenant_up's --wait: one
    # tenant is recreated and proven healthy before the next is touched, so a
    # bad image costs exactly one tenant instead of all of them. The tenants
    # already rolled stay rolled — this is a stop, not a rollback — so the
    # recovery is to fix forward, or pin the fleet back with
    # `tenant upgrade <name> --version <sha>` against the SHA tag CI pushes
    # alongside the environment tag.
    upgraded=0
    total="$(all_tenants | grep -c '^' || true)"
    while IFS= read -r t; do
      [[ -z "$t" ]] && continue
      version="${version_in:-$(conf_get "$t" version)}"; version="${version:-$env}"
      concurrency="$(conf_get "$t" concurrency)"; concurrency="${concurrency:-2}"
      conf_write "$t" "$version" "$concurrency"
      log "[$(( upgraded + 1 ))/${total}] upgrading tenant '${t}'"
      tenant_up "$t" pull
      upgraded=$(( upgraded + 1 ))
    done < <(all_tenants)
    log "upgrade-all complete: ${upgraded}/${total} tenant(s) upgraded"
    exit 0 ;;
  purge)
    if [[ "$want_yes" != true ]]; then
      warn "purge DELETES tenant '${tenant}'s data volume — its sessions, profiles, CLI accounts and stored credentials. This cannot be undone."
      confirm_typed "Type the tenant name to confirm" "$tenant" || die "confirmation failed — aborted"
    fi
    # Ordered so an interrupted `add` is fully cleaned up: each step tolerates
    # its target already being absent, so purge works on a tenant that never
    # got past step 1.
    tenant_compose "$tenant" down -v || warn "compose down reported an error (already gone?) — continuing purge"
    "${repo_root}/bin/quarantine" app remove-redirect "$APP_NAME" "$(tenant_callback "$tenant")" \
      || warn "could not remove the redirect URI (already gone?) — continuing purge"
    # Blank this tenant's generated secrets so a later tenant of the same name
    # gets a fresh key rather than silently inheriting a dead one whose
    # ciphertext went out with the volume. sops has no delete, and blanking is
    # equivalent here: export_tenant_secrets treats empty as "generate".
    purge_count="$(yq eval "[.apps[] | select(.name == \"${APP_NAME}\") | .generated_secrets[]?] | length" "${repo_root}/catalog.yaml")"
    for (( purge_i = 0; purge_i < purge_count; purge_i++ )); do
      purge_key="$(yq eval ".apps[] | select(.name == \"${APP_NAME}\") | .generated_secrets[${purge_i}].key" "${repo_root}/catalog.yaml")"
      [[ -z "$purge_key" || "$purge_key" == "null" ]] && continue
      if [[ -n "$(secrets_get "$plaintext_file" ".tenants[\"${tenant}\"].${purge_key}")" ]]; then
        secrets_set "$repo_root" "$env" ".tenants[\"${tenant}\"].${purge_key}" ""
      fi
    done
    rm -rf -- "$(tenant_dir "$tenant")"
    log "tenant '${tenant}' purged: containers, data volume, allowlist and redirect URI are all gone"
    log "note: the Zitadel identities of its members still exist — remove them separately with 'quarantine user remove <email>' if they are no longer needed anywhere"
    exit 0 ;;
esac

die "unhandled verb '${VERB}' (this is a bug in lazaretto-tenant.sh)"
