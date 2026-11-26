#!/usr/bin/env bash
# provisioners/zitadel.sh — idempotently ensure a Zitadel project + OIDC
# application exist for one catalog app (decision: Zitadel v2 resource API,
# PAT auth — confirmed against zitadel/zitadel's own .proto sources; see
# docs/architecture.md's Phase 3 notes).
#
# Not invoked directly by CI or by hand — `quarantine start` calls the
# default ("ensure") mode and the "ensure-features" mode, and `quarantine
# app add-redirect`/`remove-redirect` (bin/quarantine) call the two
# redirect modes. Both layers decrypt secrets and validate the app
# name/needs_oidc flag before reaching this script; invoking it standalone
# (e.g. for debugging) still works with a manually-decrypted plaintext
# file, per its own usage below.
#
# Usage:
#   provisioners/zitadel.sh <repo_root> <env> <plaintext_secrets_file> <name>
#       Default ("ensure") mode: create-or-heal a Zitadel Application for
#       catalog app <name> (e.g. "uptime-kuma"), matching this platform's
#       one-Application-per-catalog-app model. Every catalog app still uses
#       exactly this — nothing below changes for them.
#
#   provisioners/zitadel.sh ensure-features <repo_root> <env> <plaintext_secrets_file>
#       Instance-wide (not per-app): ensures the loginV2.required instance
#       feature is off, via the live SetInstanceFeatures API. Needed
#       because ZITADEL_DEFAULTINSTANCE_FEATURES_LOGINV2_REQUIRED (infra/
#       identity/zitadel/compose.yaml) only takes effect at first-ever
#       instance creation — confirmed live: flipping that env var and
#       restarting an already-bootstrapped instance changed nothing. Called
#       on every `quarantine start` (self-healing if ever flipped back via
#       Console) rather than once, matching every other provisioner here.
#
#   provisioners/zitadel.sh signup-status <repo_root> <env> <plaintext_secrets_file>
#   provisioners/zitadel.sh signup-set    <repo_root> <env> <plaintext_secrets_file> on|off
#       Self sign-up (the Register button on the login page). It is one
#       switch for the whole instance: `allowRegister` on the instance's
#       default login policy. signup-status prints it, and whether our org
#       uses that default (if the org has its own policy, the default does
#       nothing for it). signup-set changes only that field: the PUT
#       replaces the whole policy, so it sends back what it read, then
#       re-reads and dies if anything else changed. Called by
#       `quarantine signup`; see docs/site/guides/users/self-sign-up.md.
#
#   provisioners/zitadel.sh add-redirect <repo_root> <env> <plaintext_secrets_file> <canonical_name> <redirect_uri>
#   provisioners/zitadel.sh remove-redirect <repo_root> <env> <plaintext_secrets_file> <canonical_name> <redirect_uri>
#       Shared-Application mode: add or remove one redirect URI (and its
#       derived postLogoutRedirectUri) on <canonical_name>'s ALREADY-EXISTING
#       Application, instead of creating a new per-invocation Application.
#       <canonical_name> is the real catalog.yaml name (e.g. "lazzaretto"),
#       never a "pr-<n>-<app>" name — there is no such Application under
#       this mode, so a PR-shaped name here just fails the ListApplications
#       lookup below with a clear "no Zitadel application named ... found"
#       error rather than silently doing the wrong thing. Built for
#       lazzaretto's PR sandboxes: every PR sandbox and the persistent
#       deployment share ONE Application (one client_id/secret, no per-PR
#       secret churn, no per-PR Application left behind by a closed PR that
#       never gets torn down — see lazzaretto's own
#       docs/USER_MANAGEMENT_OIDC_ZITADEL.md, "PR preview links" section,
#       for the full rationale). Only lazzaretto uses this today; a future
#       app that's also PR-sandboxed and wants the same treatment would call
#       `quarantine app add-redirect`/`remove-redirect` the same way, keyed
#       on ITS OWN canonical name — see docs/adding-oidc-to-your-app.md.
#
#       Zitadel's ApplicationService has no per-URI add/remove RPC — only
#       UpdateApplication, which replaces the WHOLE redirectUris (and
#       postLogoutRedirectUris) list per call (confirmed against Zitadel's
#       own API reference — no PatchApplication method exists). This mode
#       therefore does a read-modify-write, serialized with flock, keyed on
#       the Application's id so two PR open/close events racing on the same
#       Application can't lose an update to each other. The lock file lives
#       under <repo_root>/.quarantine-locks/ — this ONLY serializes calls
#       that share that path, which requires <repo_root> to be the same
#       host-persistent, bind-mounted checkout every invocation runs
#       against (true for the CI runner pool's /opt/quarantine/repo mount;
#       would NOT hold if a caller ever ran this against a fresh per-job
#       checkout with no shared filesystem).
#
#   provisioners/zitadel.sh list-redirects <repo_root> <env> <plaintext_secrets_file> <canonical_name> [--json]
#       Enumerate the redirect URIs currently registered on <canonical_name>'s
#       shared Application. add-redirect/remove-redirect could write that list
#       but nothing could read it, which made it unauditable from the CLI —
#       an increasingly bad property as per-tenant instances add one entry
#       each. Read-only; never calls UpdateApplication.
#
#   provisioners/zitadel.sh user-add    <repo_root> <env> <secrets> <email> [--given-name G] [--family-name F] [--invite] [--password-stdin]
#   provisioners/zitadel.sh user-list   <repo_root> <env> <secrets> [--query <substr>] [--json]
#   provisioners/zitadel.sh user-show   <repo_root> <env> <secrets> <email> [--json]
#   provisioners/zitadel.sh user-remove <repo_root> <env> <secrets> <email>
#   provisioners/zitadel.sh user-invite <repo_root> <env> <secrets> <email>
#   provisioners/zitadel.sh user-grant  <repo_root> <env> <secrets> <email> <canonical_name> <role>
#   provisioners/zitadel.sh user-revoke <repo_root> <env> <secrets> <email> <canonical_name> <role>
#   provisioners/zitadel.sh app-add-role   <repo_root> <env> <secrets> <canonical_name> <role> [--display-name D] [--group G]
#   provisioners/zitadel.sh app-list-roles <repo_root> <env> <secrets> <canonical_name> [--json]
#       Human identity management. Provisioning an instance is only half of
#       onboarding: the person who logs in lives in Zitadel, and their
#       membership of a tenant lives in that tenant's oauth2-proxy allowlist
#       (provisioners/lazzaretto-tenant.sh). EMAIL is the join key between the
#       two, and neither half implies the other — a Zitadel user with no
#       allowlist entry authenticates and is then 403'd at the edge; an
#       allowlist entry with no Zitadel user is inert. These modes therefore
#       always take an email and resolve it to a userId themselves; no
#       operator should ever have to paste a Zitadel id.
#
#       API DECISIONS, each confirmed against the running Zitadel (v4.16.1)
#       rather than taken from documentation — several documented paths turned
#       out to be wrong:
#         - Users use the v2 REST shape (POST /v2/users for search, POST
#           /v2/users/human to create, GET/DELETE /v2/users/{id}), not the
#           Connect-RPC shape the project/application calls below use. Both
#           are served, but the REST shape is what Zitadel's own v2 docs
#           describe for these, and search doubles as the email->userId
#           resolver so the two styles don't actually mix within one mode.
#         - The invite endpoints are UNDERSCORED: /v2/users/{id}/invite_code
#           and /v2/users/{id}/invite_code/resend. The hyphenated spelling
#           (invite-code/resend) 404s.
#         - There is no email-code resend endpoint at all; the hyphenated
#           /email-code/resend and /email/_resend both 404. Re-sending an
#           address verification is POST /v2/users/{id}/email with sendCode.
#         - Grants stay on the v1 Management API (POST /management/v1/users/
#           {userId}/grants to create, POST /management/v1/users/grants/
#           _search to read, PUT .../grants/{grantId} to change roleKeys).
#           This is the one deprecated surface used here, kept deliberately:
#           the v2 authorization service is not what this Zitadel serves for
#           project-role grants today, and the per-user _search path under a
#           userId 405s — only the org-wide search with a userIdQuery filter
#           works. Revisit if a future Zitadel drops the v1 Management API;
#           it is isolated to zitadel_user_grant_find/-grant/-revoke below.
#         - Project roles are likewise v1 Management (POST /management/v1/
#           projects/{projectId}/roles, .../roles/_search).
#
#       Passwords are accepted on STDIN (--password-stdin), never as an argv
#       value, for the same reason the Authorization header below is fed over
#       stdin: argv is readable by any other local process. TENANT_OPERATIONS.md
#       originally specified a `--password VALUE` flag; that spelling is not
#       offered. --invite is strongly preferred either way — it keeps this
#       platform out of the business of handling passwords at all.
#
#   provisioners/zitadel.sh machine-add    <repo_root> <env> <secrets> <username> [--display-name D]
#   provisioners/zitadel.sh machine-list   <repo_root> <env> <secrets> [--query <substr>] [--json]
#   provisioners/zitadel.sh machine-show   <repo_root> <env> <secrets> <username> [--json]
#   provisioners/zitadel.sh machine-remove <repo_root> <env> <secrets> <username>
#   provisioners/zitadel.sh machine-grant  <repo_root> <env> <secrets> <username> <canonical_name> <role>
#   provisioners/zitadel.sh machine-revoke <repo_root> <env> <secrets> <username> <canonical_name> <role>
#       Machine (service-account) identity management — the automation-account
#       counterpart to the human user-* modes above, for the case where
#       something calls an API with no person behind it (e.g. an n8n workflow
#       calling Lazzaretto's headless API). Deliberately NOT an Application:
#       Zitadel's own client-credentials guide for service accounts confirms a
#       machine user plus a generated client secret is sufficient for the
#       OAuth2 client_credentials grant — no Project Application, no
#       oidc_redirect_uris, nothing catalog.yaml-related. Applications (the
#       "ensure" mode above) exist for a DIFFERENT thing entirely: an OIDC
#       client that puts a human through a browser login. A username IS the
#       client_id Zitadel hands back (confirmed in AddSecret's own docs: "the
#       client id is the user's username"), so these modes never need to
#       resolve or persist one separately.
#
#       machine-add generates and persists a client SECRET (AddSecret is a
#       write-once reveal, same as an Application's own GenerateClientSecret)
#       to secrets.sops.yaml at .machines["<username>"].client_secret — the
#       one thing about a machine user that can't be re-derived from Zitadel
#       later, unlike everything human-user-shaped above, which persists
#       nothing locally at all. machine-show reads it back for re-display
#       without regenerating (regenerating would invalidate whatever's
#       already pasted into a downstream credential, e.g. n8n's own OAuth2
#       credential for Lazzaretto — see apps/third-party/n8n/SETUP.md).
#
#       machine-grant/machine-revoke reuse the exact same project-role
#       read-modify-write as user-grant/user-revoke (a UserGrant is keyed on
#       userId regardless of whether that user is human or machine), just
#       resolving <username> via a machine-scoped search instead of by email.
#
#       UNTESTED AGAINST A LIVE INSTANCE as of this writing — unlike every
#       API decision documented above this point, which the user-* modes'
#       own history confirms live before trusting docs (several documented
#       paths there turned out wrong). CreateUser's machine variant
#       (POST /v2/users/new, a "machine": {"name", "description",
#       "accessTokenType"} field) and AddSecret (POST /v2/users/{id}/secret)
#       are corroborated across Zitadel's own proto source and API reference
#       docs, but not confirmed against a running instance the way every
#       other endpoint here has been. Verify machine-add end to end
#       (including the exact response field for the new user's id — sources
#       disagreed between "userId" and "id") on the first real run and correct
#       this comment once confirmed, the same way this file's own history
#       already did once for the human user-* modes.
#
# All apps share one Zitadel project ("quarantine-apps"), each as its own
# OIDC application within it — one org, one project, one app-per-catalog-app
# (or, under the shared-Application mode above, one app per catalog app
# PLUS every PR sandbox of that same app), matching this platform's
# single-tenant deployment model.
#
# Every Zitadel API call runs inside a throwaway container attached to the
# `edge` docker network, talking to zitadel-api over plain internal HTTP
# (http://zitadel-api:8080) — never through the public HTTPS route. The
# public route (https://auth.${DOMAIN}/api/...) depends on DNS propagation
# and ACME (DNS-01) cert issuance, neither of which is guaranteed to have
# completed the moment zitadel-api reports healthy (that healthcheck only
# covers Zitadel's own internal readiness); going in-network sidesteps both.
#
# API surface: Zitadel v2 resource APIs — Connect protocol, i.e. plain
# `POST /<package>.<Service>/<Method>` with a JSON body and an
# `Authorization: Bearer <PAT>` header (confirmed via zitadel/zitadel's own
# proto sources: zitadel.project.v2.ProjectService, zitadel.application.v2.
# ApplicationService) — plus one v1 Auth API call (`GET /auth/v1/users/me`)
# to resolve the provisioner's own organization ID: v2 has no "who am I"
# resource endpoint, and this session-context lookup was never part of the
# v1->v2 resource migration.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT_SELF="$(cd -P "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT_SELF}/lib/common.sh"

require_bash4
require_cmd docker sops yq flock

# --- mode + argument parsing -------------------------------------------------
MODE="ensure"
case "${1:-}" in
  add-redirect|remove-redirect|list-redirects|ensure-features|signup-status|signup-set| \
  user-add|user-list|user-show|user-remove|user-invite|user-grant|user-revoke| \
  app-add-role|app-list-roles| \
  machine-add|machine-list|machine-show|machine-remove|machine-grant|machine-revoke)
    MODE="$1"; shift ;;
esac

redirect_uri="" name="" email="" role="" role_display_name="" role_group=""
given_name="" family_name="" list_query="" username="" machine_display_name=""
signup_want=""
want_json=false want_invite=false want_password_stdin=false

# Every mode except the two that predate this block takes the same three
# leading positionals; parse them once rather than in each branch.
_take_common() {
  [[ $# -ge 3 ]] || die "usage: provisioners/zitadel.sh ${MODE} <repo_root> <env> <plaintext_secrets_file> ..."
  repo_root="$1" env="$2" plaintext_file="$3"
}

case "$MODE" in
  ensure)
    [[ $# -eq 4 ]] || die "usage: provisioners/zitadel.sh <repo_root> <env> <plaintext_secrets_file> <name>"
    repo_root="$1" env="$2" plaintext_file="$3" name="$4" ;;
  ensure-features)
    [[ $# -eq 3 ]] || die "usage: provisioners/zitadel.sh ensure-features <repo_root> <env> <plaintext_secrets_file>"
    repo_root="$1" env="$2" plaintext_file="$3" ;;
  signup-status)
    [[ $# -eq 3 ]] || die "usage: provisioners/zitadel.sh signup-status <repo_root> <env> <plaintext_secrets_file>"
    repo_root="$1" env="$2" plaintext_file="$3" ;;
  signup-set)
    [[ $# -eq 4 ]] || die "usage: provisioners/zitadel.sh signup-set <repo_root> <env> <plaintext_secrets_file> on|off"
    repo_root="$1" env="$2" plaintext_file="$3"
    case "$4" in
      on) signup_want=true ;;
      off) signup_want=false ;;
      *) die "signup-set: expected 'on' or 'off', got '$4'" ;;
    esac ;;
  add-redirect|remove-redirect)
    [[ $# -eq 5 ]] || die "usage: provisioners/zitadel.sh ${MODE} <repo_root> <env> <plaintext_secrets_file> <canonical_name> <redirect_uri>"
    repo_root="$1" env="$2" plaintext_file="$3" name="$4" redirect_uri="$5"
    [[ -n "$redirect_uri" ]] || die "${MODE}: redirect_uri must not be empty" ;;
  list-redirects|app-list-roles)
    _take_common "$@"; shift 3
    [[ $# -ge 1 ]] || die "usage: provisioners/zitadel.sh ${MODE} <repo_root> <env> <plaintext_secrets_file> <canonical_name> [--json]"
    name="$1"; shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --json) want_json=true; shift ;;
        *) die "unknown argument to ${MODE}: $1" ;;
      esac
    done ;;
  app-add-role)
    _take_common "$@"; shift 3
    [[ $# -ge 2 ]] || die "usage: provisioners/zitadel.sh app-add-role <repo_root> <env> <plaintext_secrets_file> <canonical_name> <role> [--display-name D] [--group G]"
    name="$1" role="$2"; shift 2
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --display-name) role_display_name="${2:?--display-name requires a value}"; shift 2 ;;
        --group) role_group="${2:?--group requires a value}"; shift 2 ;;
        *) die "unknown argument to app-add-role: $1" ;;
      esac
    done ;;
  user-add)
    _take_common "$@"; shift 3
    [[ $# -ge 1 ]] || die "usage: provisioners/zitadel.sh user-add <repo_root> <env> <plaintext_secrets_file> <email> [--given-name G] [--family-name F] [--invite] [--password-stdin]"
    email="$1"; shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --given-name) given_name="${2:?--given-name requires a value}"; shift 2 ;;
        --family-name) family_name="${2:?--family-name requires a value}"; shift 2 ;;
        --invite) want_invite=true; shift ;;
        --password-stdin) want_password_stdin=true; shift ;;
        # Refused rather than silently ignored: a caller reaching for this
        # is trying to hand a real password, and quietly creating a
        # password-less account instead is the worst possible outcome.
        --password) die "user-add: --password is not supported (a password in argv is readable by any local process) — pipe it to --password-stdin instead, or prefer --invite" ;;
        *) die "unknown argument to user-add: $1" ;;
      esac
    done ;;
  user-show|user-remove|user-invite)
    _take_common "$@"; shift 3
    [[ $# -ge 1 ]] || die "usage: provisioners/zitadel.sh ${MODE} <repo_root> <env> <plaintext_secrets_file> <email> [--json]"
    email="$1"; shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --json) want_json=true; shift ;;
        *) die "unknown argument to ${MODE}: $1" ;;
      esac
    done ;;
  user-grant|user-revoke)
    _take_common "$@"; shift 3
    [[ $# -eq 3 ]] || die "usage: provisioners/zitadel.sh ${MODE} <repo_root> <env> <plaintext_secrets_file> <email> <canonical_name> <role>"
    email="$1" name="$2" role="$3" ;;
  user-list)
    _take_common "$@"; shift 3
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --json) want_json=true; shift ;;
        --query) list_query="${2:?--query requires a value}"; shift 2 ;;
        *) die "unknown argument to user-list: $1" ;;
      esac
    done ;;
  machine-add)
    _take_common "$@"; shift 3
    [[ $# -ge 1 ]] || die "usage: provisioners/zitadel.sh machine-add <repo_root> <env> <plaintext_secrets_file> <username> [--display-name D]"
    username="$1"; shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --display-name) machine_display_name="${2:?--display-name requires a value}"; shift 2 ;;
        *) die "unknown argument to machine-add: $1" ;;
      esac
    done ;;
  machine-show|machine-remove)
    _take_common "$@"; shift 3
    [[ $# -ge 1 ]] || die "usage: provisioners/zitadel.sh ${MODE} <repo_root> <env> <plaintext_secrets_file> <username> [--json]"
    username="$1"; shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --json) want_json=true; shift ;;
        *) die "unknown argument to ${MODE}: $1" ;;
      esac
    done ;;
  machine-list)
    _take_common "$@"; shift 3
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --json) want_json=true; shift ;;
        --query) list_query="${2:?--query requires a value}"; shift 2 ;;
        *) die "unknown argument to machine-list: $1" ;;
      esac
    done ;;
  machine-grant|machine-revoke)
    _take_common "$@"; shift 3
    [[ $# -eq 3 ]] || die "usage: provisioners/zitadel.sh ${MODE} <repo_root> <env> <plaintext_secrets_file> <username> <canonical_name> <role>"
    username="$1" name="$2" role="$3" ;;
esac

[[ -f "$plaintext_file" ]] || die "plaintext secrets file not found: $plaintext_file"

# Same gate as postgres.sh, for the same reason: this script is directly
# invocable with bare arguments, and every one of these ends up embedded in a
# JSON request body below, where an unescaped quote would break out of the
# intended field. ensure-features and the user-* modes have no per-app name,
# so they're exempt from the name check specifically.
if [[ -n "$name" ]]; then
  [[ "$name" =~ ^[a-z][a-z0-9-]*$ ]] \
    || die "invalid name '${name}': lowercase letters, digits, hyphens only, must start with a letter"
fi
if [[ -n "$email" ]]; then
  [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] \
    || die "invalid email '${email}'"
fi
if [[ -n "$role" ]]; then
  # Zitadel role keys are free-form strings; this is the conservative subset
  # that covers every realistic key (e.g. "lazzaretto-admin") without
  # admitting a quote or backslash.
  [[ "$role" =~ ^[A-Za-z0-9._:-]+$ ]] \
    || die "invalid role '${role}': letters, digits, dot, underscore, colon, hyphen only"
fi
if [[ -n "$username" ]]; then
  # Zitadel's own username charset is broader than this, but this is also
  # the string embedded verbatim into secrets.sops.yaml's yq/sops path
  # (.machines["<username>"]) and into every JSON body below — the same
  # conservative-subset reasoning as <name> and <role> above.
  [[ "$username" =~ ^[A-Za-z0-9._-]+$ ]] \
    || die "invalid username '${username}': letters, digits, dot, underscore, hyphen only"
fi
for _v in "$given_name" "$family_name" "$role_display_name" "$role_group" "$list_query" "$machine_display_name"; do
  [[ "$_v" == *'"'* || "$_v" == *'\'* ]] \
    && die "invalid value '${_v}': double quotes and backslashes are not allowed"
done
unset _v

# PIN CHECKPOINT: curlimages/curl:8.11.1 (verified 2026-07-26) — a minimal,
# official image used only as a throwaway HTTP client inside the docker
# network; not part of the deployed stack itself.
CURL_IMAGE="curlimages/curl:8.11.1"
ZITADEL_API_CONTAINER="quarantine-zitadel-api"
ZITADEL_LOGIN_CONTAINER="quarantine-zitadel-login"
ZITADEL_NETWORK="edge"
CATALOG_FILE="${repo_root}/catalog.yaml"

# ONE ZITADEL PROJECT PER APP. Zitadel can only limit who logs in per
# project ("authorizationRequired": no role in the project, no login through
# any of its applications), so each app gets its own project, named by
# catalog.yaml's `zitadel_project` (default: the app's own name). Lazzaretto
# keeps the original shared project, quarantine-apps, because its tenants,
# PR sandboxes, token audience and machine-user grants are all tied to it.
# `zitadel_role_check: false` turns the check off (Wishora: anyone who signs
# up may use it). Apps created before this live in quarantine-apps; the
# ensure mode moves them (see "move out of the legacy project" below).
LEGACY_PROJECT_NAME="quarantine-apps"
PROJECT_NAME=""
ROLE_CHECK="true"
if [[ -n "$name" ]]; then
  PROJECT_NAME="$(yq eval ".apps[] | select(.name == \"${name}\") | .zitadel_project // .name" "$CATALOG_FILE")"
  # `== false | not`, not `// true`: yq's // treats an explicit false as
  # missing and would hand back true.
  ROLE_CHECK="$(yq eval ".apps[] | select(.name == \"${name}\") | (.zitadel_role_check == false) | not" "$CATALOG_FILE")"
fi

: "${DOMAIN:?DOMAIN must be set (inherited from load_config in bin/quarantine)}"

docker inspect "$ZITADEL_API_CONTAINER" >/dev/null 2>&1 \
  || die "zitadel-api container not running: ${ZITADEL_API_CONTAINER} (must be healthy before OIDC provisioning)"

# --- provisioner PAT bootstrap (once per environment) -----------------------
provisioner_pat="$(secrets_get "$plaintext_file" '.core.zitadel.provisioner_pat')"
if [[ -z "$provisioner_pat" || "$provisioner_pat" == CHANGEME* ]]; then
  log "capturing Zitadel provisioner PAT from the bootstrap volume (first run)"
  # zitadel-api is a scratch image with no shell, so a plain file read via
  # docker exec is not possible there. zitadel-login (Node-based) mounts the same
  # zitadel-bootstrap volume read-only and does have a shell, so read the
  # PAT through it instead.
  provisioner_pat="$(docker exec "$ZITADEL_LOGIN_CONTAINER" cat /zitadel/bootstrap/provisioner.pat 2>/dev/null)" \
    || die "failed to read the provisioner PAT from ${ZITADEL_LOGIN_CONTAINER}:/zitadel/bootstrap/provisioner.pat"
  [[ -n "$provisioner_pat" ]] || die "provisioner PAT file at ${ZITADEL_LOGIN_CONTAINER}:/zitadel/bootstrap/provisioner.pat was empty"
  secrets_set "$repo_root" "$env" '.core.zitadel.provisioner_pat' "$provisioner_pat"
  log "persisted Zitadel provisioner PAT to secrets.sops.yaml"
fi

# --- HTTP helper -------------------------------------------------------------
# zitadel_call <method> <path> [json_body]
# Runs curl inside a throwaway --rm container on the same docker network as
# zitadel-api. The Authorization header — the only actually-secret part of
# the request — is fed to curl via its `-K` config mechanism over STDIN,
# never as a docker/curl argv value: argv (unlike stdin) is visible to any
# other local process via `docker inspect`/`ps` for as long as the
# container exists. The JSON body (not secret — app names, redirect URIs)
# is passed normally via --data.
#
# A `Host: auth.${DOMAIN}` header is required on every call: Zitadel
# resolves which instance (tenant) a request belongs to from the request's
# Host/origin, matched against ZITADEL_EXTERNALDOMAIN (infra/identity/
# zitadel/compose.yaml) — not from how the TCP connection was actually
# addressed. Without it (verified empirically), every call fails with
# `{"code":5,"message":"unable to set instance using origin ... Instance
# not found"}`, since the plain http://zitadel-api:8080 URL's own Host
# header ("zitadel-api:8080") doesn't match ExternalDomain.
zitadel_call() {
  local method="$1" path="$2" body="${3:-}"
  local -a curl_args=(
    -sS --fail-with-body -K - -X "$method"
    "http://zitadel-api:8080${path}"
    -H "Host: auth.${DOMAIN}"
    -H "Content-Type: application/json"
  )
  [[ -n "$body" ]] && curl_args+=(--data "$body")
  printf 'header = "Authorization: Bearer %s"\n' "$provisioner_pat" \
    | docker run --rm -i --network "$ZITADEL_NETWORK" "$CURL_IMAGE" "${curl_args[@]}"
}

# =============================================================================
# ensure-features: instance-wide, not per-app. Exits before reaching the
# org/project/application logic below, which only "ensure" and the redirect
# modes need.
# =============================================================================
if [[ "$MODE" == "ensure-features" ]]; then
  log "ensuring Zitadel instance feature loginV2.required is disabled (Console's own OIDC redirect into Login V2 loses the authRequest context and dead-ends — zitadel/zitadel#10526, #11134, #11142; the legacy UI doesn't have this problem)"
  zitadel_call PUT /v2/features/instance '{"loginV2":{"required":false}}' >/dev/null \
    || die "failed to set Zitadel instance feature loginV2.required=false"
  exit 0
fi

# =============================================================================
# signup-status / signup-set: self sign-up, instance-wide. Like
# ensure-features, these exit here and never touch projects or apps.
# =============================================================================

# The instance default login policy, as JSON. Zitadel leaves false booleans
# out of its JSON, so a missing allowRegister means off.
signup_read_policy() {
  local resp
  resp="$(zitadel_call GET /admin/v1/policies/login)" \
    || die "failed to read the instance login policy (GET /admin/v1/policies/login): ${resp:-no response}"
  printf '%s' "$resp" | yq -p json -o json -I0 '.policy'
}

signup_print_status() {
  local policy="$1" org_resp is_default
  if [[ "$(printf '%s' "$policy" | yq -p json '.allowRegister == true')" == "true" ]]; then
    echo "sign-up: on"
  else
    echo "sign-up: off"
  fi
  org_resp="$(zitadel_call GET /management/v1/policies/login)" \
    || die "failed to read our org's login policy (GET /management/v1/policies/login): ${org_resp:-no response}"
  is_default="$(printf '%s' "$org_resp" | yq -p json '.policy.isDefault == true')"
  if [[ "$is_default" == "true" ]]; then
    echo "org uses the instance default: yes"
  else
    echo "org uses the instance default: no"
    warn "our org has its own login policy, so the instance switch does not apply to it (its own allowRegister: $(printf '%s' "$org_resp" | yq -p json '.policy.allowRegister == true'))"
  fi
}

if [[ "$MODE" == "signup-status" ]]; then
  policy="$(signup_read_policy)"
  signup_print_status "$policy"
  exit 0
fi

if [[ "$MODE" == "signup-set" ]]; then
  before="$(signup_read_policy)"
  if [[ "$(printf '%s' "$before" | yq -p json '.allowRegister == true')" == "$signup_want" ]]; then
    log "sign-up is already $([[ "$signup_want" == true ]] && echo on || echo off) — nothing to change"
    signup_print_status "$before"
    exit 0
  fi
  # The PUT replaces the whole policy. Send back what we read, minus the
  # read-only fields and the lists that have their own endpoints, with
  # only allowRegister changed.
  body="$(printf '%s' "$before" | yq -p json -o json -I0 \
    "del(.details, .isDefault, .secondFactors, .multiFactors, .idps) | .allowRegister = ${signup_want}")"
  log "setting sign-up to $([[ "$signup_want" == true ]] && echo on || echo off)"
  resp="$(zitadel_call PUT /admin/v1/policies/login "$body")" \
    || die "failed to update the instance login policy: ${resp:-no response}"
  after="$(signup_read_policy)"
  # Same policy with allowRegister and the change metadata left out must be
  # identical, or the PUT changed something we did not mean to.
  strip='del(.details, .allowRegister) | sort_keys(..)'
  if [[ "$(printf '%s' "$before" | yq -p json -o json -I0 "$strip")" \
        != "$(printf '%s' "$after" | yq -p json -o json -I0 "$strip")" ]]; then
    die "the login policy changed in more than allowRegister — check it in the Console now. before: ${before}  after: ${after}"
  fi
  [[ "$(printf '%s' "$after" | yq -p json '.allowRegister == true')" == "$signup_want" ]] \
    || die "the PUT succeeded but allowRegister did not change — check it in the Console"
  signup_print_status "$after"
  exit 0
fi

# --- resolve our own organization id ----------------------------------------
whoami_response="$(zitadel_call GET /auth/v1/users/me)" || die "failed to query /auth/v1/users/me — is the provisioner PAT valid?"
org_id="$(printf '%s' "$whoami_response" | yq -p json '.user.details.resourceOwner')"
[[ -n "$org_id" && "$org_id" != "null" ]] || die "could not resolve organization id from /auth/v1/users/me response: ${whoami_response}"

# --- ensure the shared project exists ---------------------------------------
# A function, and called on demand rather than unconditionally, because it
# CREATES the project when it's missing. The user-* modes that only touch
# people (add/list/show/remove/invite) have no business bringing a project
# into existence as a side effect of, say, listing users on a fresh
# environment. The modes that genuinely need a project id — the redirect and
# role modes, plus user-grant/user-revoke, which grant a role that only
# exists on a project — call this explicitly.
#
# projectRoleAssertion ("Assert Roles on Authentication") is NOT Zitadel's
# default, and without it no token carries the project's roles, even with
# the urn:zitadel:iam:org:projects:roles scope and idTokenRoleAssertion on
# the Application. A role an app reads from a person's ID token (like
# lazzaretto-admin) then silently reads as absent: the grant exists, the
# user signs in fine, and the app just never sees it.
#
# Found live: dev had it on (flipped by hand at some point), prod had it off,
# so lazzaretto-admin worked on dev and did nothing on prod, with nothing in
# either log to say why. It's set on create, and healed on an existing
# project by the modes that make roles matter (ensure and the grant modes),
# so the two environments can't drift apart again.
project_id=""
ensure_project_id() {
  [[ -n "$project_id" ]] && return 0
  [[ -n "$PROJECT_NAME" ]] || die "'${name}' is not in catalog.yaml, so it has no Zitadel project"
  local list_proj_body list_proj_response create_proj_body create_proj_response role_assertion role_check
  list_proj_body="$(printf '{"filters":[{"projectNameFilter":{"projectName":"%s"}},{"organizationIdFilter":{"organizationId":"%s"}}]}' "$PROJECT_NAME" "$org_id")"
  list_proj_response="$(zitadel_call POST /zitadel.project.v2.ProjectService/ListProjects "$list_proj_body")" \
    || die "failed to list Zitadel projects"
  project_id="$(printf '%s' "$list_proj_response" | yq -p json '.projects[0].projectId')"

  if [[ -z "$project_id" || "$project_id" == "null" ]]; then
    log "creating Zitadel project '${PROJECT_NAME}' (role required to log in: ${ROLE_CHECK})"
    create_proj_body="$(printf '{"organizationId":"%s","name":"%s","projectRoleAssertion":true,"authorizationRequired":%s}' "$org_id" "$PROJECT_NAME" "$ROLE_CHECK")"
    create_proj_response="$(zitadel_call POST /zitadel.project.v2.ProjectService/CreateProject "$create_proj_body")" \
      || die "failed to create Zitadel project '${PROJECT_NAME}'"
    project_id="$(printf '%s' "$create_proj_response" | yq -p json '.projectId')"
    [[ -n "$project_id" && "$project_id" != "null" ]] || die "CreateProject did not return a projectId: ${create_proj_response}"
  else
    log "using existing Zitadel project '${PROJECT_NAME}' (${project_id})"
    case "$MODE" in
      ensure|user-grant|machine-grant)
        role_assertion="$(printf '%s' "$list_proj_response" | yq -p json '.projects[0].projectRoleAssertion // false')"
        if [[ "$role_assertion" != "true" ]]; then
          log "turning on projectRoleAssertion for '${PROJECT_NAME}' (${project_id}): without it no token carries the project's roles"
          zitadel_call POST /zitadel.project.v2.ProjectService/UpdateProject \
            "$(printf '{"projectId":"%s","projectRoleAssertion":true}' "$project_id")" >/dev/null \
            || die "failed to turn on projectRoleAssertion for Zitadel project '${PROJECT_NAME}'"
        fi
        ;;
    esac
    # Only `ensure` (every `quarantine start`) sets the login check, so a
    # project switched by hand in the Console is put back on the next start.
    if [[ "$MODE" == "ensure" ]]; then
      role_check="$(printf '%s' "$list_proj_response" | yq -p json '.projects[0].authorizationRequired // false')"
      if [[ "$role_check" != "$ROLE_CHECK" ]]; then
        log "setting 'role required to log in' to ${ROLE_CHECK} on '${PROJECT_NAME}' (${project_id})"
        zitadel_call POST /zitadel.project.v2.ProjectService/UpdateProject \
          "$(printf '{"projectId":"%s","authorizationRequired":%s}' "$project_id" "$ROLE_CHECK")" >/dev/null \
          || die "failed to set authorizationRequired on Zitadel project '${PROJECT_NAME}'"
      fi
    fi
  fi
}

case "$MODE" in
  ensure|add-redirect|remove-redirect|list-redirects|app-add-role|app-list-roles|user-grant|user-revoke| \
  machine-grant|machine-revoke)
    ensure_project_id ;;
esac

# A redirectUris entry is always an /oauth2/callback URL; Zitadel's
# end_session_endpoint checks post_logout_redirect_uri against the
# SEPARATE postLogoutRedirectUris list, not redirectUris (confirmed against
# Zitadel's own end_session_endpoint docs) — derive the bare origin from
# the same URI rather than taking a second one from callers.
oauth2_callback_to_origin() {
  printf '%s' "${1%/oauth2/callback}"
}

# =============================================================================
# Shared helpers for the read/identity modes below.
# =============================================================================

# zitadel_call_private <method> <path> <json_body>
# Same as zitadel_call, but feeds the request BODY through curl's -K config
# on stdin alongside the Authorization header, instead of via --data in argv.
# zitadel_call's own comment notes its bodies are "not secret — app names,
# redirect URIs", which is true of every mode that predates this one. It is
# NOT true of user-add --password-stdin, whose body carries a real password,
# and argv is readable by any other local process via `docker inspect`/`ps`
# for as long as the container exists. Used only where the body is sensitive;
# everything else stays on the plainer, easier-to-debug zitadel_call.
#
# Bodies here are always built single-line via printf, which matters: a
# curl config value is terminated by its line ending, so an embedded literal
# newline would silently truncate the request.
zitadel_call_private() {
  local method="$1" path="$2" body="$3" escaped
  escaped="$(printf '%s' "$body" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
  {
    printf 'header = "Authorization: Bearer %s"\n' "$provisioner_pat"
    printf 'data = "%s"\n' "$escaped"
  } | docker run --rm -i --network "$ZITADEL_NETWORK" "$CURL_IMAGE" \
        -sS --fail-with-body -K - -X "$method" \
        "http://zitadel-api:8080${path}" \
        -H "Host: auth.${DOMAIN}" \
        -H "Content-Type: application/json"
}

# find_application_id <name> — the Application id for one catalog app within
# its own project, or empty. Never creates.
find_application_id() {
  local app="$1" body response
  body="$(printf '{"filters":[{"projectIdFilter":{"projectId":"%s"}},{"nameFilter":{"name":"%s"}}]}' "$project_id" "$app")"
  response="$(zitadel_call POST /zitadel.application.v2.ApplicationService/ListApplications "$body")" \
    || die "failed to list Zitadel applications for project '${PROJECT_NAME}'"
  printf '%s' "$response" | yq -p json '.applications[0].applicationId // ""'
}

# The one place the shape of a "user" in every --json output is defined, so
# `user list` and `user show` can never drift apart. Applied to a single
# element of ListUsers' own `result` array.
USER_PROJECTION='{
  "userId": .userId,
  "email": (.human.email.email // ""),
  "emailVerified": (.human.email.isVerified // false),
  "username": (.username // ""),
  "givenName": (.human.profile.givenName // ""),
  "familyName": (.human.profile.familyName // ""),
  "displayName": (.human.profile.displayName // ""),
  "state": (.state // "")
}'

# search_users <extra_query_json> — POST /v2/users restricted to human users.
# Machine users (the provisioner's own PAT identity among them) are excluded
# everywhere in these modes: they are not people an operator onboards, and
# including them would make `user list` misleading the moment a second
# service account exists.
#
# Zitadel's default page size is small and silent; ask for the documented
# maximum and warn if the total still exceeds what came back, rather than
# quietly presenting a truncated list as if it were complete.
search_users() {
  local extra="${1:-}" body response total returned
  if [[ -n "$extra" ]]; then
    body="$(printf '{"queries":[{"typeQuery":{"type":"TYPE_HUMAN"}},%s],"query":{"limit":1000}}' "$extra")"
  else
    body="$(printf '{"queries":[{"typeQuery":{"type":"TYPE_HUMAN"}}],"query":{"limit":1000}}')"
  fi
  response="$(zitadel_call POST /v2/users "$body")" || die "failed to search Zitadel users"
  total="$(printf '%s' "$response" | yq -p json '.details.totalResult // "0"')"
  returned="$(printf '%s' "$response" | yq -p json '(.result // []) | length')"
  if [[ "$total" =~ ^[0-9]+$ ]] && (( total > returned )); then
    warn "Zitadel reported ${total} matching users but returned ${returned} — this listing is TRUNCATED"
  fi
  printf '%s' "$response"
}

# resolve_user_id <email> — userId for a human user with exactly this email,
# or empty. Email is the join key between Zitadel and a tenant's allowlist,
# so this is what keeps every mode's <email> argument from ever needing to
# become a pasted id.
resolve_user_id() {
  local addr="$1"
  search_users "$(printf '{"emailQuery":{"emailAddress":"%s","method":"TEXT_QUERY_METHOD_EQUALS"}}' "$addr")" \
    | yq -p json '(.result // [])[0].userId // ""'
}

# require_user_id <email> — resolve or die with an actionable message.
require_user_id() {
  local addr="$1" uid
  uid="$(resolve_user_id "$addr")"
  [[ -n "$uid" ]] || die "no Zitadel user with email '${addr}' — create one first: quarantine user add ${addr} --invite"
  printf '%s' "$uid"
}

# The machine counterpart to USER_PROJECTION — no email/givenName/familyName
# (machine users don't have a human profile), display name comes from the
# "name" field on the machine profile instead.
MACHINE_PROJECTION='{
  "userId": .userId,
  "username": (.username // ""),
  "displayName": (.machine.name // ""),
  "description": (.machine.description // ""),
  "state": (.state // "")
}'

# search_machines <extra_query_json> — POST /v2/users restricted to machine
# users, the mirror image of search_users' TYPE_HUMAN filter. Same pagination
# caveat as search_users: ask for the documented maximum and warn rather than
# silently truncate.
search_machines() {
  local extra="${1:-}" body response total returned
  if [[ -n "$extra" ]]; then
    body="$(printf '{"queries":[{"typeQuery":{"type":"TYPE_MACHINE"}},%s],"query":{"limit":1000}}' "$extra")"
  else
    body="$(printf '{"queries":[{"typeQuery":{"type":"TYPE_MACHINE"}}],"query":{"limit":1000}}')"
  fi
  response="$(zitadel_call POST /v2/users "$body")" || die "failed to search Zitadel machine users"
  total="$(printf '%s' "$response" | yq -p json '.details.totalResult // "0"')"
  returned="$(printf '%s' "$response" | yq -p json '(.result // []) | length')"
  if [[ "$total" =~ ^[0-9]+$ ]] && (( total > returned )); then
    warn "Zitadel reported ${total} matching machine users but returned ${returned} — this listing is TRUNCATED"
  fi
  printf '%s' "$response"
}

# resolve_machine_id <username> — userId for a machine user with exactly this
# username, or empty. A username is unique org-wide in Zitadel (it's also the
# client_id), so this is as reliable a join key as email is for humans.
resolve_machine_id() {
  local uname="$1"
  search_machines "$(printf '{"userNameQuery":{"userName":"%s","method":"TEXT_QUERY_METHOD_EQUALS"}}' "$uname")" \
    | yq -p json '(.result // [])[0].userId // ""'
}

# require_machine_id <username> — resolve or die with an actionable message.
require_machine_id() {
  local uname="$1" mid
  mid="$(resolve_machine_id "$uname")"
  [[ -n "$mid" ]] || die "no Zitadel machine user named '${uname}' — create one first: quarantine machine add ${uname}"
  printf '%s' "$mid"
}

# machine_secret_key <username> — the secrets.sops.yaml path a machine user's
# client secret lives at. A function (not a plain variable) because every
# machine-* mode that touches it needs the SAME username-dependent path, and
# repeating the printf inline three times invites exactly the kind of typo
# that would silently read/write the wrong key.
machine_secret_key() {
  printf '.machines["%s"].client_secret' "$1"
}

# smtp_configured — does this Zitadel instance have any SMTP provider at all?
#
# This has to be asked UP FRONT, because a mail failure is invisible from the
# API. Zitadel's invite/verification endpoints return 200 the moment they
# queue the notification, and delivery happens later in a separate worker; a
# missing provider surfaces only as `could not create email channel` in the
# server's own log, never in the response. An earlier version of this script
# only fell back to returning the code when the API call itself errored — a
# condition that never occurs — so it cheerfully reported "invite emailed" for
# mail that was never sent. Confirmed against both live instances, neither of
# which has ever had SMTP configured.
smtp_configured() {
  local response count
  response="$(zitadel_call POST /admin/v1/smtp/_search '{"query":{"limit":1}}' 2>/dev/null)" || return 1
  count="$(printf '%s' "$response" | yq -p json '(.result // []) | length' 2>/dev/null)"
  [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 ))
}

# issue_invite <user_id> <email> [resend]
# Emails the invite when this instance can actually send mail, and otherwise
# returns the code for the operator to relay — rather than claiming to have
# sent something. Shared by user-add --invite and user-invite so the two can
# never disagree about what happened.
issue_invite() {
  local uid="$1" addr="$2" resend="${3:-false}" path response code
  if smtp_configured; then
    path="/v2/users/${uid}/invite_code"
    [[ "$resend" == true ]] && path="${path}/resend"
    if zitadel_call POST "$path" '{"sendCode":{}}' >/dev/null 2>&1; then
      log "invite emailed to ${addr}"
      return 0
    fi
    warn "Zitadel has an SMTP provider but rejected the send for ${addr} — falling back to a returned code"
  else
    warn "this Zitadel instance has NO SMTP provider configured, so it cannot deliver mail."
    warn "Nothing was emailed. Configure one in the Console (Settings -> Notifications -> SMTP),"
    warn "or relay this code to ${addr} yourself:"
  fi

  if response="$(zitadel_call POST "/v2/users/${uid}/invite_code" '{"returnCode":{}}' 2>/dev/null)"; then
    code="$(printf '%s' "$response" | yq -p json '.inviteCode // ""')"
    [[ -n "$code" ]] || { warn "Zitadel returned no invite code: ${response}"; return 1; }
    warn "  invite code for ${addr}: ${code}"
    warn "  they redeem it at https://auth.${DOMAIN}/ui/login/user/init?userID=${uid}&code=${code}"
    return 0
  fi
  warn "could not issue an invite for '${addr}' at all — retry with: quarantine user invite ${addr}"
  return 1
}

# =============================================================================
# list-redirects: read-only counterpart to add-redirect/remove-redirect.
# =============================================================================
if [[ "$MODE" == "list-redirects" ]]; then
  app_id="$(find_application_id "$name")"
  [[ -n "$app_id" ]] \
    || die "no Zitadel application named '${name}' found in project '${PROJECT_NAME}' — run the default (ensure) mode for '${name}' first"

  list_response="$(zitadel_call POST /zitadel.application.v2.ApplicationService/ListApplications \
    "$(printf '{"filters":[{"projectIdFilter":{"projectId":"%s"}},{"nameFilter":{"name":"%s"}}]}' "$project_id" "$name")")" \
    || die "failed to read application '${name}'"

  if [[ "$want_json" == true ]]; then
    printf '%s' "$list_response" | yq -p json -o json \
      "{\"app\": \"${name}\",
        \"applicationId\": .applications[0].applicationId,
        \"redirectUris\": (.applications[0].oidcConfiguration.redirectUris // []),
        \"postLogoutRedirectUris\": (.applications[0].oidcConfiguration.postLogoutRedirectUris // [])}"
  else
    log "redirect URIs on '${name}' (${app_id}):"
    printf '%s' "$list_response" | yq -p json '(.applications[0].oidcConfiguration.redirectUris // [])[]'
  fi
  exit 0
fi

# =============================================================================
# app-add-role / app-list-roles
#
# Zitadel roles belong to the PROJECT, not to an individual Application —
# quarantine-apps holds one Application per catalog app but a single, shared
# role list. <canonical_name> therefore selects which project to act on
# (always the shared one today) and is validated as a real catalog app so a
# typo can't silently create a role nobody will ever see; it does NOT scope
# the role itself. Keys are conventionally app-prefixed for that reason —
# "lazzaretto-admin", which is exactly the key lazzaretto-backend's AuthService
# scans for in the urn:zitadel:iam:org:project:<id>:roles claim.
# =============================================================================
if [[ "$MODE" == "app-add-role" ]]; then
  # Keys are read into a string first and grepped from a here-string: in a
  # `yq ... | grep -q` pipeline under pipefail, grep can exit before yq has
  # finished writing, yq dies of SIGPIPE, and an existing role reads as
  # missing (seen live on dev, intermittently).
  roles_response="$(zitadel_call POST "/management/v1/projects/${project_id}/roles/_search" '{"query":{"limit":1000}}')" \
    || die "failed to list roles on project '${PROJECT_NAME}'"
  if grep -qxF "$role" <<<"$(printf '%s' "$roles_response" | yq -p json '(.result // [])[].key')"; then
    log "role '${role}' already exists on project '${PROJECT_NAME}' (${project_id}) — nothing to do"
    exit 0
  fi
  body="$(printf '{"roleKey":"%s","displayName":"%s","group":"%s"}' \
    "$role" "${role_display_name:-$role}" "$role_group")"
  zitadel_call POST "/management/v1/projects/${project_id}/roles" "$body" >/dev/null \
    || die "failed to add role '${role}' to project '${PROJECT_NAME}'"
  log "added role '${role}' to project '${PROJECT_NAME}' (${project_id})"
  exit 0
fi

if [[ "$MODE" == "app-list-roles" ]]; then
  roles_response="$(zitadel_call POST "/management/v1/projects/${project_id}/roles/_search" '{"query":{"limit":1000}}')" \
    || die "failed to list roles on project '${PROJECT_NAME}'"
  if [[ "$want_json" == true ]]; then
    printf '%s' "$roles_response" | yq -p json -o json \
      "{\"app\": \"${name}\",
        \"projectId\": \"${project_id}\",
        \"roles\": [(.result // [])[] | {\"key\": .key, \"displayName\": (.displayName // \"\"), \"group\": (.group // \"\")}]}"
  else
    log "roles on project '${PROJECT_NAME}' (${project_id}):"
    printf '%s' "$roles_response" | yq -p json '(.result // [])[].key'
  fi
  exit 0
fi

# =============================================================================
# user-list / user-show
# =============================================================================
if [[ "$MODE" == "user-list" ]]; then
  if [[ -n "$list_query" ]]; then
    # displayNameQuery with CONTAINS is the closest thing to a free-text
    # filter the v2 search offers across name and login name.
    users_response="$(search_users "$(printf '{"displayNameQuery":{"displayName":"%s","method":"TEXT_QUERY_METHOD_CONTAINS_IGNORE_CASE"}}' "$list_query")")"
  else
    users_response="$(search_users)"
  fi

  if [[ "$want_json" == true ]]; then
    printf '%s' "$users_response" | yq -p json -o json \
      "{\"users\": [(.result // [])[] | ${USER_PROJECTION}] | sort_by(.email)}"
  else
    printf '%s' "$users_response" | yq -p json \
      "[(.result // [])[] | ${USER_PROJECTION}] | sort_by(.email) | .[]
       | .email + \"\t\" + .state + \"\t\" + .displayName"
  fi
  exit 0
fi

if [[ "$MODE" == "user-show" ]]; then
  users_response="$(search_users "$(printf '{"emailQuery":{"emailAddress":"%s","method":"TEXT_QUERY_METHOD_EQUALS"}}' "$email")")"
  found="$(printf '%s' "$users_response" | yq -p json '(.result // []) | length')"
  [[ "$found" != "0" ]] || die "no Zitadel user with email '${email}'"

  if [[ "$want_json" == true ]]; then
    printf '%s' "$users_response" | yq -p json -o json "{\"user\": ((.result // [])[0] | ${USER_PROJECTION})}"
  else
    printf '%s' "$users_response" | yq -p json "(.result // [])[0] | ${USER_PROJECTION} | to_entries | .[] | .key + \": \" + (.value | tostring)"
  fi
  exit 0
fi

# =============================================================================
# user-add — idempotent by email.
#
# "Heals and exits 0" means: an existing user with this email is reported and
# left alone, never duplicated. It deliberately does NOT overwrite an
# existing profile from the flags passed here — a re-run of an onboarding
# command should not quietly rename a person who has since corrected their
# own name in the Console.
# =============================================================================
if [[ "$MODE" == "user-add" ]]; then
  existing_id="$(resolve_user_id "$email")"
  if [[ -n "$existing_id" ]]; then
    log "Zitadel user '${email}' already exists (${existing_id}) — nothing to do"
    log "note: an existing profile is never overwritten here; change names in the Console"
    exit 0
  fi

  # Zitadel requires both name parts on a human profile. Defaulting them to
  # the address's local part keeps `user add <email>` a valid one-liner while
  # --given-name/--family-name stay the right way to do it properly.
  local_part="${email%%@*}"
  [[ -n "$given_name" ]] || given_name="$local_part"
  [[ -n "$family_name" ]] || family_name="$local_part"

  password_json=""
  if [[ "$want_password_stdin" == true ]]; then
    IFS= read -r -s supplied_password || true
    [[ -n "$supplied_password" ]] || die "user-add --password-stdin: no password was read from stdin"
    # Escaped, never echoed, and carried to Zitadel over stdin rather than
    # argv (see zitadel_call_private).
    password_json="$(printf ',"password":{"password":"%s","changeRequired":true}' \
      "$(_json_escape_string "$supplied_password")")"
    unset supplied_password
  fi

  # sendCode asks Zitadel to email a verification/invite code. isVerified is
  # deliberately NOT set: marking an address verified without the person ever
  # proving control of it defeats the point of the invite.
  create_body="$(printf '{"username":"%s","organization":{"orgId":"%s"},"profile":{"givenName":"%s","familyName":"%s"},"email":{"email":"%s","sendCode":{}}%s}' \
    "$email" "$org_id" "$given_name" "$family_name" "$email" "$password_json")"

  if [[ -n "$password_json" ]]; then
    create_response="$(zitadel_call_private POST /v2/users/human "$create_body")" \
      || die "failed to create Zitadel user '${email}'"
  else
    create_response="$(zitadel_call POST /v2/users/human "$create_body")" \
      || die "failed to create Zitadel user '${email}'"
  fi
  unset create_body password_json

  new_user_id="$(printf '%s' "$create_response" | yq -p json '.userId // ""')"
  [[ -n "$new_user_id" ]] || die "AddHumanUser did not return a userId: ${create_response}"
  log "created Zitadel user '${email}' (${new_user_id})"

  if [[ "$want_invite" == true ]]; then
    # Never fails the onboarding: the user exists either way, and an
    # environment with no mail delivery is a reason to hand the code over
    # directly, not to unwind a successful creation.
    issue_invite "$new_user_id" "$email" false || true
  fi
  exit 0
fi

if [[ "$MODE" == "user-invite" ]]; then
  user_id="$(require_user_id "$email")"
  issue_invite "$user_id" "$email" true \
    || die "failed to issue an invite for '${email}' (${user_id})"
  exit 0
fi

if [[ "$MODE" == "user-remove" ]]; then
  user_id="$(resolve_user_id "$email")"
  if [[ -z "$user_id" ]]; then
    log "no Zitadel user with email '${email}' — nothing to do"
    exit 0
  fi
  zitadel_call DELETE "/v2/users/${user_id}" >/dev/null \
    || die "failed to delete Zitadel user '${email}' (${user_id})"
  log "deleted Zitadel user '${email}' (${user_id})"
  log "note: this removes the IDENTITY only. Any tenant allowlist still naming ${email} is now inert but should be cleaned up: quarantine tenant member remove <tenant> ${email}"
  exit 0
fi

# =============================================================================
# user-grant / user-revoke — project-role grants.
#
# A user has at most ONE grant per project, carrying a LIST of role keys, so
# both modes are a read-modify-write of that list rather than a create/delete
# of a grant per role. Revoking the last role deletes the grant outright,
# which is what leaves no empty husk behind for the next grant to trip over.
# =============================================================================
if [[ "$MODE" == "user-grant" || "$MODE" == "user-revoke" ]]; then
  user_id="$(require_user_id "$email")"

  # Guard against granting a role that doesn't exist: Zitadel accepts unknown
  # role keys on a grant, and the result is a claim nobody's authorization
  # code will ever match — a silent no-op that looks like success.
  roles_response="$(zitadel_call POST "/management/v1/projects/${project_id}/roles/_search" '{"query":{"limit":1000}}')" \
    || die "failed to list roles on project '${PROJECT_NAME}'"
  if ! grep -qxF "$role" <<<"$(printf '%s' "$roles_response" | yq -p json '(.result // [])[].key')"; then
    die "role '${role}' does not exist on project '${PROJECT_NAME}' — create it first: quarantine app add-role ${name} ${role}"
  fi

  grants_response="$(zitadel_call POST /management/v1/users/grants/_search \
    "$(printf '{"query":{"limit":1000},"queries":[{"userIdQuery":{"userId":"%s"}},{"projectIdQuery":{"projectId":"%s"}}]}' "$user_id" "$project_id")")" \
    || die "failed to search existing grants for '${email}'"
  grant_id="$(printf '%s' "$grants_response" | yq -p json '(.result // [])[0].id // ""')"
  current_roles_json="$(printf '%s' "$grants_response" | yq -p json -o json '(.result // [])[0].roleKeys // []')"

  if [[ "$MODE" == "user-grant" ]]; then
    new_roles_json="$(printf '%s' "$current_roles_json" | yq -p json -o json ". + [\"${role}\"] | unique" -)"
  else
    new_roles_json="$(printf '%s' "$current_roles_json" | yq -p json -o json "[.[] | select(. != \"${role}\")]" -)"
  fi

  if [[ "$new_roles_json" == "$current_roles_json" ]]; then
    log "${MODE}: '${email}' already matches the desired roles on '${name}' — nothing to do"
    exit 0
  fi

  new_role_count="$(printf '%s' "$new_roles_json" | yq -p json 'length')"
  if [[ -z "$grant_id" ]]; then
    zitadel_call POST "/management/v1/users/${user_id}/grants" \
      "$(printf '{"projectId":"%s","roleKeys":%s}' "$project_id" "$new_roles_json")" >/dev/null \
      || die "failed to create a grant for '${email}' on '${name}'"
    log "granted '${role}' to ${email} on '${name}'"
  elif (( new_role_count == 0 )); then
    zitadel_call DELETE "/management/v1/users/${user_id}/grants/${grant_id}" >/dev/null \
      || die "failed to delete the now-empty grant for '${email}'"
    log "revoked '${role}' from ${email} — that was the last role, so the grant itself was removed"
  else
    zitadel_call PUT "/management/v1/users/${user_id}/grants/${grant_id}" \
      "$(printf '{"roleKeys":%s}' "$new_roles_json")" >/dev/null \
      || die "failed to update the grant for '${email}' on '${name}'"
    log "${MODE#user-}d '${role}' for ${email} on '${name}'"
  fi
  exit 0
fi

# =============================================================================
# machine-list / machine-show — read-only, mirrors user-list/user-show.
# =============================================================================
if [[ "$MODE" == "machine-list" ]]; then
  if [[ -n "$list_query" ]]; then
    # displayNameQuery is user-list's own filter, copied here unverified: it
    # matches a HUMAN profile's displayName in every confirmed-live example
    # in this file, and whether it also matches a machine's "name" field
    # (this mode's own MACHINE_PROJECTION.displayName) through the same
    # /v2/users search is untested. Low-stakes if wrong — --query just
    # returns nothing instead of the expected match; `machine list` with no
    # --query is unaffected.
    machines_response="$(search_machines "$(printf '{"displayNameQuery":{"displayName":"%s","method":"TEXT_QUERY_METHOD_CONTAINS_IGNORE_CASE"}}' "$list_query")")"
  else
    machines_response="$(search_machines)"
  fi

  if [[ "$want_json" == true ]]; then
    printf '%s' "$machines_response" | yq -p json -o json \
      "{\"machines\": [(.result // [])[] | ${MACHINE_PROJECTION}] | sort_by(.username)}"
  else
    printf '%s' "$machines_response" | yq -p json \
      "[(.result // [])[] | ${MACHINE_PROJECTION}] | sort_by(.username) | .[]
       | .username + \"\t\" + .state + \"\t\" + .displayName"
  fi
  exit 0
fi

if [[ "$MODE" == "machine-show" ]]; then
  machines_response="$(search_machines "$(printf '{"userNameQuery":{"userName":"%s","method":"TEXT_QUERY_METHOD_EQUALS"}}' "$username")")"
  found="$(printf '%s' "$machines_response" | yq -p json '(.result // []) | length')"
  [[ "$found" != "0" ]] || die "no Zitadel machine user named '${username}'"

  # Revealed here deliberately, not withheld like user-show's total silence
  # on secrets: unlike a human, a machine user's own secret has nowhere else
  # for an operator to look it up (Zitadel itself never returns it again
  # after AddSecret) — this is the re-display path machine-add's own header
  # comment promises. Anyone who can run this already has sops-decrypt
  # access to the whole secrets.sops.yaml file, so this reveals nothing they
  # couldn't already read directly.
  client_secret="$(secrets_get "$plaintext_file" "$(machine_secret_key "$username")")"

  if [[ "$want_json" == true ]]; then
    # _json_escape_string, not a bare interpolation: unlike every other
    # value spliced into a yq/jq expression string in this file (app
    # names, roles — all gated to a safe charset above), a secret is
    # arbitrary data with no charset guarantee, same reasoning as
    # user-add's own password handling.
    printf '%s' "$machines_response" | yq -p json -o json \
      "{\"machine\": ((.result // [])[0] | ${MACHINE_PROJECTION} + {\"clientSecret\": \"$(_json_escape_string "$client_secret")\"})}"
  else
    printf '%s' "$machines_response" | yq -p json "(.result // [])[0] | ${MACHINE_PROJECTION} | to_entries | .[] | .key + \": \" + (.value | tostring)"
    log "clientSecret: ${client_secret:-<none persisted — was this user created outside machine-add?>}"
  fi
  exit 0
fi

# =============================================================================
# machine-add — idempotent by username. Existing-and-persisted heals and
# exits 0, same "never overwrite a name from the Console" contract as
# user-add. Existing-but-NOT-persisted (interrupted prior run — same shape as
# the OIDC "ensure" mode's own defensive branch further down) regenerates a
# secret rather than leaving a machine user nobody can ever authenticate as.
# =============================================================================
if [[ "$MODE" == "machine-add" ]]; then
  existing_id="$(resolve_machine_id "$username")"
  if [[ -n "$existing_id" ]]; then
    existing_secret="$(secrets_get "$plaintext_file" "$(machine_secret_key "$username")")"
    if [[ -n "$existing_secret" && "$existing_secret" != CHANGEME* ]]; then
      log "Zitadel machine user '${username}' already exists (${existing_id}) with a persisted secret — nothing to do"
      log "note: an existing profile is never overwritten here; change it in the Console"
      exit 0
    fi
    log "Zitadel machine user '${username}' exists (${existing_id}) but has no persisted secret (interrupted prior run) — regenerating"
    secret_response="$(zitadel_call POST "/v2/users/${existing_id}/secret" '{}')" \
      || die "failed to generate a client secret for existing machine user '${username}'"
    new_secret="$(printf '%s' "$secret_response" | yq -p json '.clientSecret // ""')"
    [[ -n "$new_secret" ]] || die "AddSecret did not return a clientSecret: ${secret_response}"
    secrets_set "$repo_root" "$env" "$(machine_secret_key "$username")" "$new_secret"
    log "Zitadel machine user '${username}' ready — client_id=${username}"
    warn "client_secret (shown once, now persisted to secrets.sops.yaml — retrieve again later with 'quarantine machine show ${username}'):"
    warn "  ${new_secret}"
    exit 0
  fi

  display_name="${machine_display_name:-$username}"
  # accessTokenType: JWT, not the server default (BEARER, an opaque
  # reference token) — Lazzaretto's own forwarded-identity contract
  # (docs/adding-oidc-to-your-app.md) already requires every first-party
  # backend to verify a self-contained JWT against Zitadel's JWKS rather
  # than call back into Zitadel to introspect an opaque token; a machine
  # user calling that same API should carry the same kind of token.
  create_body="$(printf '{"organizationId":"%s","username":"%s","machine":{"name":"%s","description":"quarantine-managed automation account","accessTokenType":"ACCESS_TOKEN_TYPE_JWT"}}' \
    "$org_id" "$username" "$display_name")"
  create_response="$(zitadel_call POST /v2/users/new "$create_body")" \
    || die "failed to create Zitadel machine user '${username}'"
  unset create_body

  # Sources disagreed on the response field name for this newer, unified
  # CreateUser endpoint (some examples show "userId", others "id") — see
  # this file's own header comment on why this mode is unconfirmed against a
  # live instance. Checking both rather than guessing wrong and dying on a
  # confusing "userId did not return" message when the value was right there
  # under the other name.
  new_machine_id="$(printf '%s' "$create_response" | yq -p json '.userId // .id // ""')"
  [[ -n "$new_machine_id" ]] || die "CreateUser did not return a userId (checked both 'userId' and 'id'): ${create_response}"
  log "created Zitadel machine user '${username}' (${new_machine_id})"

  secret_response="$(zitadel_call POST "/v2/users/${new_machine_id}/secret" '{}')" \
    || die "created machine user '${username}' but failed to generate its client secret — retry with: provisioners/zitadel.sh machine-add ... ${username} (idempotent: will heal, not duplicate)"
  new_secret="$(printf '%s' "$secret_response" | yq -p json '.clientSecret // ""')"
  [[ -n "$new_secret" ]] || die "AddSecret did not return a clientSecret: ${secret_response}"
  secrets_set "$repo_root" "$env" "$(machine_secret_key "$username")" "$new_secret"

  log "Zitadel machine user '${username}' ready — client_id=${username}"
  warn "client_secret (shown once, now persisted to secrets.sops.yaml — retrieve again later with 'quarantine machine show ${username}'):"
  warn "  ${new_secret}"
  exit 0
fi

if [[ "$MODE" == "machine-remove" ]]; then
  machine_id="$(resolve_machine_id "$username")"
  if [[ -z "$machine_id" ]]; then
    log "no Zitadel machine user named '${username}' — nothing to do"
    exit 0
  fi
  zitadel_call DELETE "/v2/users/${machine_id}" >/dev/null \
    || die "failed to delete Zitadel machine user '${username}' (${machine_id})"
  log "deleted Zitadel machine user '${username}' (${machine_id})"
  log "note: this removes the IDENTITY only. secrets.sops.yaml still carries its now-orphaned client secret at $(machine_secret_key "$username") — harmless (nothing can authenticate as a deleted user) but worth cleaning up by hand if this environment is ever restored from this file."
  exit 0
fi

# =============================================================================
# machine-grant / machine-revoke — project-role grants, mirroring
# user-grant/user-revoke's own read-modify-write EXACTLY (a UserGrant is
# keyed on userId regardless of whether that user is human or machine) —
# duplicated rather than factored out into a shared helper so this new,
# not-yet-live-verified path can never regress the already-working human one.
# =============================================================================
if [[ "$MODE" == "machine-grant" || "$MODE" == "machine-revoke" ]]; then
  user_id="$(require_machine_id "$username")"

  roles_response="$(zitadel_call POST "/management/v1/projects/${project_id}/roles/_search" '{"query":{"limit":1000}}')" \
    || die "failed to list roles on project '${PROJECT_NAME}'"
  if ! grep -qxF "$role" <<<"$(printf '%s' "$roles_response" | yq -p json '(.result // [])[].key')"; then
    die "role '${role}' does not exist on project '${PROJECT_NAME}' — create it first: quarantine app add-role ${name} ${role}"
  fi

  grants_response="$(zitadel_call POST /management/v1/users/grants/_search \
    "$(printf '{"query":{"limit":1000},"queries":[{"userIdQuery":{"userId":"%s"}},{"projectIdQuery":{"projectId":"%s"}}]}' "$user_id" "$project_id")")" \
    || die "failed to search existing grants for '${username}'"
  grant_id="$(printf '%s' "$grants_response" | yq -p json '(.result // [])[0].id // ""')"
  current_roles_json="$(printf '%s' "$grants_response" | yq -p json -o json '(.result // [])[0].roleKeys // []')"

  if [[ "$MODE" == "machine-grant" ]]; then
    new_roles_json="$(printf '%s' "$current_roles_json" | yq -p json -o json ". + [\"${role}\"] | unique" -)"
  else
    new_roles_json="$(printf '%s' "$current_roles_json" | yq -p json -o json "[.[] | select(. != \"${role}\")]" -)"
  fi

  if [[ "$new_roles_json" == "$current_roles_json" ]]; then
    log "${MODE}: '${username}' already matches the desired roles on '${name}' — nothing to do"
    exit 0
  fi

  new_role_count="$(printf '%s' "$new_roles_json" | yq -p json 'length')"
  if [[ -z "$grant_id" ]]; then
    zitadel_call POST "/management/v1/users/${user_id}/grants" \
      "$(printf '{"projectId":"%s","roleKeys":%s}' "$project_id" "$new_roles_json")" >/dev/null \
      || die "failed to create a grant for '${username}' on '${name}'"
    log "granted '${role}' to ${username} on '${name}'"
  elif (( new_role_count == 0 )); then
    zitadel_call DELETE "/management/v1/users/${user_id}/grants/${grant_id}" >/dev/null \
      || die "failed to delete the now-empty grant for '${username}'"
    log "revoked '${role}' from ${username} — that was the last role, so the grant itself was removed"
  else
    zitadel_call PUT "/management/v1/users/${user_id}/grants/${grant_id}" \
      "$(printf '{"roleKeys":%s}' "$new_roles_json")" >/dev/null \
      || die "failed to update the grant for '${username}' on '${name}'"
    # Not "${MODE#machine-}d" (that reads "machine-grant" -> "grant" + "d" =
    # "grantd", a real bug already present in user-grant/user-revoke's own
    # identical shorthand below — not fixed there in this PR to avoid
    # touching that already-live-verified path, but not worth repeating in
    # new code either).
    if [[ "$MODE" == "machine-grant" ]]; then
      log "granted '${role}' for ${username} on '${name}'"
    else
      log "revoked '${role}' for ${username} on '${name}'"
    fi
  fi
  exit 0
fi

# =============================================================================
# add-redirect / remove-redirect: shared-Application redirect-URI
# read-modify-write. Exits before reaching the "ensure" (create-or-heal)
# logic below, which only the default mode uses.
# =============================================================================
if [[ "$MODE" == "add-redirect" || "$MODE" == "remove-redirect" ]]; then
  find_app_body="$(printf '{"filters":[{"projectIdFilter":{"projectId":"%s"}},{"nameFilter":{"name":"%s"}}]}' "$project_id" "$name")"
  find_app_response="$(zitadel_call POST /zitadel.application.v2.ApplicationService/ListApplications "$find_app_body")" \
    || die "failed to list Zitadel applications for project '${PROJECT_NAME}'"
  app_id="$(printf '%s' "$find_app_response" | yq -p json '.applications[0].applicationId')"
  [[ -n "$app_id" && "$app_id" != "null" ]] \
    || die "no Zitadel application named '${name}' found in project '${PROJECT_NAME}' — run the default (ensure) mode for '${name}' first; ${MODE} only ever modifies an existing Application, never creates one"

  logout_redirect_uri="$(oauth2_callback_to_origin "$redirect_uri")"

  lock_dir="${repo_root}/.quarantine-locks"
  mkdir -p "$lock_dir"
  lock_file="${lock_dir}/zitadel-app-${app_id}.lock"

  log "${MODE}: waiting for lock on Zitadel application '${name}' (${app_id})"
  (
    flock -w 30 9 || die "timed out waiting for the lock on Zitadel application '${name}' (${app_id}) — another add-redirect/remove-redirect call is stuck holding it"

    # Re-fetch INSIDE the lock: the ListApplications call above (before the
    # lock was held) may already be stale if another add-redirect/
    # remove-redirect call for this same application ran in between.
    locked_get_response="$(zitadel_call POST /zitadel.application.v2.ApplicationService/ListApplications "$find_app_body")" \
      || die "failed to re-fetch Zitadel application '${name}' (${app_id}) under lock"
    current_redirects_json="$(printf '%s' "$locked_get_response" | yq -p json -o json '.applications[0].oidcConfiguration.redirectUris // []')"
    current_logout_redirects_json="$(printf '%s' "$locked_get_response" | yq -p json -o json '.applications[0].oidcConfiguration.postLogoutRedirectUris // []')"

    if [[ "$MODE" == "add-redirect" ]]; then
      new_redirects_json="$(printf '%s' "$current_redirects_json" | yq -p json -o json ". + [\"${redirect_uri}\"] | unique" -)"
      new_logout_redirects_json="$(printf '%s' "$current_logout_redirects_json" | yq -p json -o json ". + [\"${logout_redirect_uri}\"] | unique" -)"
      log "add-redirect: adding ${redirect_uri} to '${name}' (${app_id})"
    else
      new_redirects_json="$(printf '%s' "$current_redirects_json" | yq -p json -o json "[.[] | select(. != \"${redirect_uri}\")]" -)"
      new_logout_redirects_json="$(printf '%s' "$current_logout_redirects_json" | yq -p json -o json "[.[] | select(. != \"${logout_redirect_uri}\")]" -)"
      log "remove-redirect: removing ${redirect_uri} from '${name}' (${app_id})"
    fi

    # Zitadel's UpdateApplication has no idempotent no-op response of its
    # own -- calling it with a redirect list identical to what's already
    # stored 400s with {"code":"failed_precondition","message":"No changes"}
    # instead of a harmless 200. That's the ordinary case for add-redirect,
    # not an exceptional one: pr-sandbox-up.yml calls this on every push to
    # an open PR, and only the first push for a given PR number actually
    # changes anything -- every push after that would otherwise fail CI on
    # a call that has nothing left to do (confirmed live: lazzaretto PR #18's
    # second push failed exactly this way). Symmetrically covers
    # remove-redirect against a URI that's already gone (a PR closed twice,
    # or closed after a failed add). Comparing here, before ever calling
    # UpdateApplication, both prevents the wasted call and sidesteps having
    # to pattern-match a specific error response to tell "already done"
    # apart from a real failure.
    if [[ "$new_redirects_json" == "$current_redirects_json" && "$new_logout_redirects_json" == "$current_logout_redirects_json" ]]; then
      log "${MODE}: '${redirect_uri}' on '${name}' (${app_id}) already matches the desired state -- nothing to do"
      exit 0
    fi

    update_body="$(cat <<JSON
{
  "applicationId": "${app_id}",
  "projectId": "${project_id}",
  "oidcConfiguration": {
    "redirectUris": ${new_redirects_json},
    "postLogoutRedirectUris": ${new_logout_redirects_json}
  }
}
JSON
)"
    zitadel_call POST /zitadel.application.v2.ApplicationService/UpdateApplication "$update_body" \
      || die "UpdateApplication failed for '${name}' (${app_id})"
    log "${MODE} succeeded for '${name}' (${app_id})"
  ) 9>"$lock_file"

  exit 0
fi

# =============================================================================
# ensure (default): create-or-heal, unchanged from before add-redirect/
# remove-redirect existed.
# =============================================================================

# --- roles from catalog.yaml (zitadel_roles) ---------------------------------
# Create the missing ones; never delete (a removed role would silently drop
# it from every grant).
roles_response="$(zitadel_call POST "/management/v1/projects/${project_id}/roles/_search" '{"query":{"limit":1000}}')" \
  || die "failed to list roles on project '${PROJECT_NAME}'"
while IFS= read -r want_role; do
  [[ -z "$want_role" ]] && continue
  [[ "$want_role" =~ ^[A-Za-z0-9._:-]+$ ]] || die "invalid role '${want_role}' in catalog.yaml for '${name}'"
  if ! grep -qxF "$want_role" <<<"$(printf '%s' "$roles_response" | yq -p json '(.result // [])[].key')"; then
    zitadel_call POST "/management/v1/projects/${project_id}/roles" \
      "$(printf '{"roleKey":"%s","displayName":"%s"}' "$want_role" "$want_role")" >/dev/null \
      || die "failed to add role '${want_role}' to project '${PROJECT_NAME}'"
    log "added role '${want_role}' to project '${PROJECT_NAME}'"
  fi
done < <(yq eval ".apps[] | select(.name == \"${name}\") | .zitadel_roles[]?" "$CATALOG_FILE")

# --- roles for people who sign up through this app (zitadel_signup_roles) ----
# Zitadel has no default role per project, so this is a Zitadel Action
# (Actions v1) on the org's Internal Authentication flow, Post Creation
# trigger. It runs when someone makes their own account with the login
# page's Register form, never for `quarantine user add` or the Console. It
# adds the roles only when the sign-up began at THIS app's login request
# (ctx.v1.authRequest.applicationId is the OIDC client id), so the same
# Register form reached from another app gives nothing. Existing accounts
# are not touched.
#
# One action per app, named signupRoles_<app>: Zitadel calls the function
# whose name equals the action's. allowedToFail, so a broken action never
# blocks a sign-up; the person just ends up without the role, which can be
# granted by hand. Removing zitadel_signup_roles removes the action on the
# next start.
#
# Checked against Zitadel v4.16.1's source: runPostCreationActions in
# internal/api/ui/login/custom_action.go, mapObjectToGrant in
# internal/actions/object/user_grant.go, and ApplicationID = ClientID in
# internal/api/oidc/auth_request_converter.go. Actions v1 run in the v1
# login UI, which is the one this platform uses (see ensure-features).
FLOW_INTERNAL_AUTHENTICATION=3   # domain.FlowTypeInternalAuthentication
TRIGGER_POST_CREATION=3          # domain.TriggerTypePostCreation

# set_post_creation_actions <json array of action ids>
set_post_creation_actions() {
  zitadel_call POST "/management/v1/flows/${FLOW_INTERNAL_AUTHENTICATION}/trigger/${TRIGGER_POST_CREATION}" \
    "$(printf '{"actionIds":%s}' "$1")" >/dev/null \
    || die "failed to set the actions on Zitadel's Internal Authentication / Post Creation trigger"
}

# ensure_signup_roles <client_id> — called once the app's client id is final.
ensure_signup_roles() {
  local app_client_id="$1"
  local action_name="signupRoles_${name//[^A-Za-z0-9]/_}"
  local roles_json all_roles want_role search_response action_id current_script
  local flow_response trigger_ids script body

  roles_json="$(yq eval -o json -I0 "[.apps[] | select(.name == \"${name}\") | .zitadel_signup_roles[]?]" "$CATALOG_FILE")"

  search_response="$(zitadel_call POST /management/v1/actions/_search \
    "$(printf '{"queries":[{"actionNameQuery":{"name":"%s","method":"TEXT_QUERY_METHOD_EQUALS"}}]}' "$action_name")")" \
    || die "failed to search Zitadel actions"
  action_id="$(printf '%s' "$search_response" | yq -p json '(.result // [])[0].id // ""')"
  current_script="$(printf '%s' "$search_response" | yq -p json '(.result // [])[0].script // ""')"

  flow_response="$(zitadel_call GET "/management/v1/flows/${FLOW_INTERNAL_AUTHENTICATION}")" \
    || die "failed to read Zitadel's Internal Authentication flow"
  trigger_ids="$(printf '%s' "$flow_response" | yq -p json -o json -I0 \
    "[(.flow.triggerActions // [])[] | select(.triggerType.id == \"${TRIGGER_POST_CREATION}\") | .actions[].id]")"

  if [[ "$roles_json" == "[]" ]]; then
    [[ -n "$action_id" ]] || return 0
    if grep -qxF "$action_id" <<<"$(printf '%s' "$trigger_ids" | yq -p json '.[]')"; then
      set_post_creation_actions "$(printf '%s' "$trigger_ids" | yq -p json -o json -I0 "[.[] | select(. != \"${action_id}\")]")"
    fi
    zitadel_call DELETE "/management/v1/actions/${action_id}" >/dev/null \
      || die "failed to delete the Zitadel action '${action_name}'"
    log "removed the sign-up action '${action_name}': '${name}' has no zitadel_signup_roles"
    return 0
  fi

  all_roles="$(yq eval ".apps[] | select(.name == \"${name}\") | .zitadel_roles[]?" "$CATALOG_FILE")"
  while IFS= read -r want_role; do
    grep -qxF "$want_role" <<<"$all_roles" \
      || die "zitadel_signup_roles for '${name}' lists '${want_role}', which is not in its zitadel_roles"
  done < <(printf '%s' "$roles_json" | yq -p json '.[]')

  script="$(cat <<JS
// Managed by the platform's provisioners/zitadel.sh (catalog.yaml
// zitadel_signup_roles for '${name}'). Changes made here are overwritten.
function ${action_name}(ctx, api) {
  var request = ctx.v1.authRequest;
  if (!request || request.applicationId !== "${app_client_id}") {
    return;
  }
  api.v1.appendUserGrant({ projectID: "${project_id}", roles: ${roles_json} });
}
JS
)"
  body="$(N="$action_name" S="$script" yq -n -o json -I0 \
    '.name = strenv(N) | .script = strenv(S) | .timeout = "10s" | .allowedToFail = true')"

  if [[ -z "$action_id" ]]; then
    action_id="$(zitadel_call POST /management/v1/actions "$body" | yq -p json '.id // ""')"
    [[ -n "$action_id" ]] || die "failed to create the Zitadel action '${action_name}'"
    log "created the sign-up action '${action_name}' (roles: ${roles_json})"
  elif [[ "$current_script" != "$script" ]]; then
    zitadel_call PUT "/management/v1/actions/${action_id}" "$body" >/dev/null \
      || die "failed to update the Zitadel action '${action_name}'"
    log "updated the sign-up action '${action_name}' (roles: ${roles_json})"
  fi

  if ! grep -qxF "$action_id" <<<"$(printf '%s' "$trigger_ids" | yq -p json '.[]')"; then
    set_post_creation_actions "$(printf '%s' "$trigger_ids" | yq -p json -o json -I0 ". + [\"${action_id}\"]")"
    log "'${action_name}' now runs after every self sign-up (Internal Authentication / Post Creation)"
  fi
}

# --- the project id, for apps that read roles from a project-scoped claim ----
# (Kujtime: urn:zitadel:iam:org:project:<id>:roles.) Written only when it
# changes, because every write re-encrypts secrets.sops.yaml and leaves the
# checkout dirty.
project_id_key=".apps[\"${name}\"].zitadel_project_id"
if [[ "$(secrets_get "$plaintext_file" "$project_id_key")" != "$project_id" ]]; then
  secrets_set "$repo_root" "$env" "$project_id_key" "$project_id"
fi

# --- if already provisioned in its own project, we're done -------------------
client_id_key=".apps[\"${name}\"].oidc_client_id"
client_secret_key=".apps[\"${name}\"].oidc_client_secret"
client_id="$(secrets_get "$plaintext_file" "$client_id_key")"

# --- move out of the legacy project -------------------------------------------
# Zitadel can't move an Application between projects. An app still living in
# quarantine-apps gets a NEW Application in its own project (new client id
# and secret, persisted below and picked up by the .env that `quarantine
# start` regenerates right after this), carrying over every redirect URI the
# old one had (Kujtime city callbacks, PR preview callbacks), and the old
# Application is deleted. Everyone signed in to that app logs in again.
legacy_app_id="" legacy_project_id="" additional_origins_json="[]"
declare -a legacy_redirects=() legacy_logout_redirects=()

if [[ -n "$client_id" && "$client_id" != CHANGEME* ]]; then
  if [[ -n "$(find_application_id "$name")" ]]; then
    log "Zitadel OIDC application for '${name}' already provisioned in project '${PROJECT_NAME}' — skipping"
    ensure_signup_roles "$client_id"
    exit 0
  fi
  if [[ "$PROJECT_NAME" != "$LEGACY_PROJECT_NAME" ]]; then
    legacy_project_id="$(zitadel_call POST /zitadel.project.v2.ProjectService/ListProjects \
      "$(printf '{"filters":[{"projectNameFilter":{"projectName":"%s"}},{"organizationIdFilter":{"organizationId":"%s"}}]}' "$LEGACY_PROJECT_NAME" "$org_id")" \
      | yq -p json '.projects[0].projectId // ""')" || die "failed to list Zitadel projects"
  fi
  if [[ -n "$legacy_project_id" ]]; then
    legacy_response="$(zitadel_call POST /zitadel.application.v2.ApplicationService/ListApplications \
      "$(printf '{"filters":[{"projectIdFilter":{"projectId":"%s"}},{"nameFilter":{"name":"%s"}}]}' "$legacy_project_id" "$name")")" \
      || die "failed to list Zitadel applications in '${LEGACY_PROJECT_NAME}'"
    legacy_app_id="$(printf '%s' "$legacy_response" | yq -p json '.applications[0].applicationId // ""')"
  fi
  [[ -n "$legacy_app_id" ]] \
    || die "'${name}' has a persisted client_id but no Application in '${PROJECT_NAME}' or '${LEGACY_PROJECT_NAME}' — clear ${client_id_key} in secrets.sops.yaml to create a new one"
  while IFS= read -r uri; do [[ -n "$uri" ]] && legacy_redirects+=("$uri"); done \
    < <(printf '%s' "$legacy_response" | yq -p json '.applications[0].oidcConfiguration.redirectUris[]?')
  while IFS= read -r uri; do [[ -n "$uri" ]] && legacy_logout_redirects+=("$uri"); done \
    < <(printf '%s' "$legacy_response" | yq -p json '.applications[0].oidcConfiguration.postLogoutRedirectUris[]?')
  # Kujtime's city origins live here, not in the redirect list.
  additional_origins_json="$(printf '%s' "$legacy_response" | yq -p json -o json -I0 '.applications[0].oidcConfiguration.additionalOrigins // []')"
  log "moving '${name}' from '${LEGACY_PROJECT_NAME}' to its own project '${PROJECT_NAME}' (new client id; ${#legacy_redirects[@]} redirect URI(s) carried over)"
fi

# --- redirect URIs, from catalog.yaml with ${DOMAIN} substituted ------------
redirect_uri_count="$(yq eval "[.apps[] | select(.name == \"${name}\") | .oidc_redirect_uris[]] | length" "$CATALOG_FILE")"
(( redirect_uri_count > 0 )) || die "'${name}' has no oidc_redirect_uris in catalog.yaml"

declare -a redirect_uris=()
declare -a logout_redirect_uris=()
while IFS= read -r uri; do
  [[ -z "$uri" ]] && continue
  resolved_uri="${uri//\$\{DOMAIN\}/$DOMAIN}"
  redirect_uris+=("$resolved_uri")
  logout_redirect_uris+=("$(oauth2_callback_to_origin "$resolved_uri")")
done < <(yq eval ".apps[] | select(.name == \"${name}\") | .oidc_redirect_uris[]" "$CATALOG_FILE")
# "${arr[@]}" with no ":-" fallback: bash >= 4.4, an empty array expands to nothing.
redirect_uris+=("${legacy_redirects[@]}")
logout_redirect_uris+=("${legacy_logout_redirects[@]}")

# Built via yq's own YAML->JSON conversion (correct JSON-escaping for free)
# rather than hand-quoting each URI into a JSON array string.
redirect_uris_json="$(printf -- '- %s\n' "${redirect_uris[@]}" | yq -o json - | yq -p json -o json 'unique' -)"
# unique: catalog.yaml lists exactly one redirect URI per app today, so
# there's nothing to actually dedupe yet — cheap insurance against a future
# entry with multiple hosts whose callback URIs share a bare origin.
logout_redirect_uris_json="$(printf -- '- %s\n' "${logout_redirect_uris[@]}" | yq -o json - | yq -p json -o json 'unique' -)"

# --- defensive: app may already exist without a persisted client_id --------
# (e.g. a prior run created the Zitadel application but was killed before
# secrets_set persisted the result). Look it up by name within the project
# first, rather than blindly creating a duplicate application.
find_app_body="$(printf '{"filters":[{"projectIdFilter":{"projectId":"%s"}},{"nameFilter":{"name":"%s"}}]}' "$project_id" "$name")"
find_app_response="$(zitadel_call POST /zitadel.application.v2.ApplicationService/ListApplications "$find_app_body")" \
  || die "failed to list Zitadel applications for project '${PROJECT_NAME}'"
existing_app_id="$(printf '%s' "$find_app_response" | yq -p json '.applications[0].applicationId')"

if [[ -n "$existing_app_id" && "$existing_app_id" != "null" ]]; then
  log "found existing Zitadel application '${name}' without a persisted client_id (interrupted prior run) — regenerating its client secret"
  existing_client_id="$(printf '%s' "$find_app_response" | yq -p json '.applications[0].oidcConfiguration.clientId')"
  [[ -n "$existing_client_id" && "$existing_client_id" != "null" ]] \
    || die "existing application '${name}' has no OIDC client_id — was it created as a non-OIDC app type?"

  regen_body="$(printf '{"applicationId":"%s","projectId":"%s"}' "$existing_app_id" "$project_id")"
  regen_response="$(zitadel_call POST /zitadel.application.v2.ApplicationService/GenerateClientSecret "$regen_body")" \
    || die "failed to regenerate client secret for existing application '${name}'"
  new_secret="$(printf '%s' "$regen_response" | yq -p json '.clientSecret')"
  [[ -n "$new_secret" && "$new_secret" != "null" ]] || die "GenerateClientSecret did not return a clientSecret: ${regen_response}"

  secrets_set "$repo_root" "$env" "$client_id_key" "$existing_client_id"
  secrets_set "$repo_root" "$env" "$client_secret_key" "$new_secret"
  log "Zitadel OIDC application ready for '${name}' (client secret regenerated on an app found without persisted credentials)"
  ensure_signup_roles "$existing_client_id"
  exit 0
fi

# --- fresh create ------------------------------------------------------------
# OIDC_AUTH_METHOD_TYPE_BASIC (client_secret_basic) is the OAuth2 spec
# default and the broadest-compatible choice across Immich / Stirling PDF /
# oauth2-proxy's OIDC clients; if real deployment testing against any of
# these three shows it expects client_secret_post instead, change this one
# field to OIDC_AUTH_METHOD_TYPE_POST for that app — nothing else here is
# app-specific enough to need touching.
#
# idTokenUserinfoAssertion is NOT Zitadel's default and has to be asked for.
# Without it the id_token carries sub/iss/aud and nothing else — no email, no
# name — and under the oauth2-proxy model that token is the ONLY thing a
# first-party backend ever sees. Lazzaretto's AuthService reads email and name
# straight off those claims, so it stores empty strings and every user shows
# up nameless: a blank display name, a blank email, and an avatar falling
# back to "?" because there are no initials to derive.
#
# Found live: prod had it false and dev had it true, so the same build looked
# correct on one environment and broken on the other, with nothing in either
# log to say why. Dev was evidently flipped by hand at some point; prod was
# bootstrapped later and got the default. Setting it here is what stops the
# two drifting again.
#
# Existing applications are NOT retrofitted by this — CreateApplication only
# runs for an app that does not exist yet. Flip it in the console for any app
# already created (Project -> Application -> Token Settings -> "User Info
# inside ID Token"). The next request then backfills the user row on its own,
# because findOrCreateUser re-assigns email and displayName on every call
# rather than only at creation.
create_app_body="$(cat <<JSON
{
  "projectId": "${project_id}",
  "name": "${name}",
  "oidcConfiguration": {
    "redirectUris": ${redirect_uris_json},
    "postLogoutRedirectUris": ${logout_redirect_uris_json},
    "responseTypes": ["OIDC_RESPONSE_TYPE_CODE"],
    "grantTypes": ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"],
    "applicationType": "OIDC_APP_TYPE_WEB",
    "authMethodType": "OIDC_AUTH_METHOD_TYPE_BASIC",
    "version": "OIDC_VERSION_1_0",
    "idTokenUserinfoAssertion": true,
    "idTokenRoleAssertion": true,
    "additionalOrigins": ${additional_origins_json}
  }
}
JSON
)"
create_app_response="$(zitadel_call POST /zitadel.application.v2.ApplicationService/CreateApplication "$create_app_body")" \
  || die "failed to create Zitadel OIDC application for '${name}'"
new_client_id="$(printf '%s' "$create_app_response" | yq -p json '.oidcConfiguration.clientId')"
new_client_secret="$(printf '%s' "$create_app_response" | yq -p json '.oidcConfiguration.clientSecret')"
[[ -n "$new_client_id" && "$new_client_id" != "null" ]] || die "CreateApplication did not return a clientId: ${create_app_response}"
[[ -n "$new_client_secret" && "$new_client_secret" != "null" ]] || die "CreateApplication did not return a clientSecret: ${create_app_response}"

secrets_set "$repo_root" "$env" "$client_id_key" "$new_client_id"
secrets_set "$repo_root" "$env" "$client_secret_key" "$new_client_secret"
log "Zitadel OIDC application created for '${name}' in project '${PROJECT_NAME}'"

if [[ -n "$legacy_app_id" ]]; then
  zitadel_call POST /zitadel.application.v2.ApplicationService/DeleteApplication \
    "$(printf '{"applicationId":"%s","projectId":"%s"}' "$legacy_app_id" "$legacy_project_id")" >/dev/null \
    || die "created '${name}' in '${PROJECT_NAME}' but failed to delete the old Application ${legacy_app_id} in '${LEGACY_PROJECT_NAME}' — delete it in the Console"
  log "deleted the old '${name}' Application from '${LEGACY_PROJECT_NAME}'"
  warn "role grants for '${name}' made on '${LEGACY_PROJECT_NAME}' do not move: grant them again with 'quarantine user grant <email> ${name} <role>'"
fi

ensure_signup_roles "$new_client_id"
