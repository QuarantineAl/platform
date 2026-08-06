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
#   provisioners/zitadel.sh add-redirect <repo_root> <env> <plaintext_secrets_file> <canonical_name> <redirect_uri>
#   provisioners/zitadel.sh remove-redirect <repo_root> <env> <plaintext_secrets_file> <canonical_name> <redirect_uri>
#       Shared-Application mode: add or remove one redirect URI (and its
#       derived postLogoutRedirectUri) on <canonical_name>'s ALREADY-EXISTING
#       Application, instead of creating a new per-invocation Application.
#       <canonical_name> is the real catalog.yaml name (e.g. "lazaretto"),
#       never a "pr-<n>-<app>" name — there is no such Application under
#       this mode, so a PR-shaped name here just fails the ListApplications
#       lookup below with a clear "no Zitadel application named ... found"
#       error rather than silently doing the wrong thing. Built for
#       lazaretto's PR sandboxes: every PR sandbox and the persistent
#       deployment share ONE Application (one client_id/secret, no per-PR
#       secret churn, no per-PR Application left behind by a closed PR that
#       never gets torn down — see lazaretto's own
#       docs/USER_MANAGEMENT_OIDC_ZITADEL.md, "PR preview links" section,
#       for the full rationale). Only lazaretto uses this today; a future
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
if [[ "${1:-}" == "add-redirect" || "${1:-}" == "remove-redirect" || "${1:-}" == "ensure-features" ]]; then
  MODE="$1"
  shift
fi

redirect_uri=""
name=""
if [[ "$MODE" == "ensure" ]]; then
  if [[ $# -ne 4 ]]; then
    die "usage: provisioners/zitadel.sh <repo_root> <env> <plaintext_secrets_file> <name>"
  fi
  repo_root="$1" env="$2" plaintext_file="$3" name="$4"
elif [[ "$MODE" == "ensure-features" ]]; then
  if [[ $# -ne 3 ]]; then
    die "usage: provisioners/zitadel.sh ensure-features <repo_root> <env> <plaintext_secrets_file>"
  fi
  repo_root="$1" env="$2" plaintext_file="$3"
else
  if [[ $# -ne 5 ]]; then
    die "usage: provisioners/zitadel.sh ${MODE} <repo_root> <env> <plaintext_secrets_file> <canonical_name> <redirect_uri>"
  fi
  repo_root="$1" env="$2" plaintext_file="$3" name="$4" redirect_uri="$5"
  [[ -n "$redirect_uri" ]] || die "${MODE}: redirect_uri must not be empty"
fi

[[ -f "$plaintext_file" ]] || die "plaintext secrets file not found: $plaintext_file"
# Same gate as postgres.sh, for the same reason: this script is directly
# invocable with a bare name argument, and `name` ends up embedded in JSON
# request bodies below. ensure-features has no per-app name, so it's exempt.
if [[ "$MODE" != "ensure-features" ]]; then
  [[ "$name" =~ ^[a-z][a-z0-9-]*$ ]] \
    || die "invalid name '${name}': lowercase letters, digits, hyphens only, must start with a letter"
fi

# PIN CHECKPOINT: curlimages/curl:8.11.1 (verified 2026-07-26) — a minimal,
# official image used only as a throwaway HTTP client inside the docker
# network; not part of the deployed stack itself.
CURL_IMAGE="curlimages/curl:8.11.1"
ZITADEL_API_CONTAINER="quarantine-zitadel-api"
ZITADEL_LOGIN_CONTAINER="quarantine-zitadel-login"
ZITADEL_NETWORK="edge"
PROJECT_NAME="quarantine-apps"
CATALOG_FILE="${repo_root}/catalog.yaml"

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

# --- resolve our own organization id ----------------------------------------
whoami_response="$(zitadel_call GET /auth/v1/users/me)" || die "failed to query /auth/v1/users/me — is the provisioner PAT valid?"
org_id="$(printf '%s' "$whoami_response" | yq -p json '.user.details.resourceOwner')"
[[ -n "$org_id" && "$org_id" != "null" ]] || die "could not resolve organization id from /auth/v1/users/me response: ${whoami_response}"

# --- ensure the shared project exists ---------------------------------------
list_proj_body="$(printf '{"filters":[{"projectNameFilter":{"projectName":"%s"}},{"organizationIdFilter":{"organizationId":"%s"}}]}' "$PROJECT_NAME" "$org_id")"
list_proj_response="$(zitadel_call POST /zitadel.project.v2.ProjectService/ListProjects "$list_proj_body")" \
  || die "failed to list Zitadel projects"
project_id="$(printf '%s' "$list_proj_response" | yq -p json '.projects[0].projectId')"

if [[ -z "$project_id" || "$project_id" == "null" ]]; then
  log "creating Zitadel project '${PROJECT_NAME}'"
  create_proj_body="$(printf '{"organizationId":"%s","name":"%s"}' "$org_id" "$PROJECT_NAME")"
  create_proj_response="$(zitadel_call POST /zitadel.project.v2.ProjectService/CreateProject "$create_proj_body")" \
    || die "failed to create Zitadel project '${PROJECT_NAME}'"
  project_id="$(printf '%s' "$create_proj_response" | yq -p json '.projectId')"
  [[ -n "$project_id" && "$project_id" != "null" ]] || die "CreateProject did not return a projectId: ${create_proj_response}"
else
  log "using existing Zitadel project '${PROJECT_NAME}' (${project_id})"
fi

# A redirectUris entry is always an /oauth2/callback URL; Zitadel's
# end_session_endpoint checks post_logout_redirect_uri against the
# SEPARATE postLogoutRedirectUris list, not redirectUris (confirmed against
# Zitadel's own end_session_endpoint docs) — derive the bare origin from
# the same URI rather than taking a second one from callers.
oauth2_callback_to_origin() {
  printf '%s' "${1%/oauth2/callback}"
}

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

# --- if already provisioned, we're done -------------------------------------
client_id_key=".apps[\"${name}\"].oidc_client_id"
client_secret_key=".apps[\"${name}\"].oidc_client_secret"
client_id="$(secrets_get "$plaintext_file" "$client_id_key")"

if [[ -n "$client_id" && "$client_id" != CHANGEME* ]]; then
  log "Zitadel OIDC application for '${name}' already provisioned (client_id persisted) — skipping"
  exit 0
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

# Built via yq's own YAML->JSON conversion (correct JSON-escaping for free)
# rather than hand-quoting each URI into a JSON array string.
redirect_uris_json="$(printf -- '- %s\n' "${redirect_uris[@]}" | yq -o json -)"
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
  exit 0
fi

# --- fresh create ------------------------------------------------------------
# OIDC_AUTH_METHOD_TYPE_BASIC (client_secret_basic) is the OAuth2 spec
# default and the broadest-compatible choice across Immich / Stirling PDF /
# oauth2-proxy's OIDC clients; if real deployment testing against any of
# these three shows it expects client_secret_post instead, change this one
# field to OIDC_AUTH_METHOD_TYPE_POST for that app — nothing else here is
# app-specific enough to need touching.
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
    "version": "OIDC_VERSION_1_0"
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
log "Zitadel OIDC application created for '${name}'"
