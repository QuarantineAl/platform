#!/usr/bin/env bash
# scripts/new-app.sh — scaffold a new catalog app.
#
# Usage: scripts/new-app.sh <name> <kind> [--subdomain <sub>] [--image <ref>]
#   <name>   catalog/profile name, e.g. "paperless" (lowercase, hyphens ok)
#   <kind>   "third-party" or "first-party"
#
# Creates apps/<kind>/<name>/compose.yaml (convention-compliant: joins the
# edge network, Traefik labels for <subdomain>.${DOMAIN}, a healthcheck
# placeholder, image pinned via ${<APP>_VERSION}) and appends a matching
# entry to catalog.yaml. Idempotent: refuses to touch anything if the app
# folder or a catalog entry with this name already exists — re-run after
# manually removing both if you really want to start over.
#
# This is a dev/maintenance helper (not invoked by `quarantine start`),
# hence scripts/ rather than bin/ or provisioners/.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -P "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

require_bash4
require_cmd yq

usage() {
  cat <<'EOF'
Usage: scripts/new-app.sh <name> <kind> [--subdomain <sub>] [--image <ref>]

  <name>   catalog/profile name, e.g. "paperless" (lowercase, hyphens ok)
  <kind>   "third-party" or "first-party"

Options:
  --subdomain <sub>   Host prefix for Traefik routing (default: <name>)
  --image <ref>        Image reference to pre-fill (default: a CHANGEME
                        placeholder — third-party apps rarely have a
                        knowable ${<APP>_VERSION}-pinned tag at scaffold
                        time; first-party apps default to
                        ghcr.io/<org>/<name>)
EOF
}

if [[ $# -lt 2 ]]; then
  usage >&2
  die "expected at least <name> and <kind>"
fi

app_name="$1"; shift
kind="$1"; shift

subdomain="$app_name"
image_ref=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subdomain) subdomain="$2"; shift 2 ;;
    --image) image_ref="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "$app_name" =~ ^[a-z][a-z0-9-]*$ ]] || die "invalid name '${app_name}': lowercase letters, digits, hyphens only, must start with a letter"
case "$kind" in
  third-party|first-party) ;;
  *) die "invalid kind '${kind}': must be 'third-party' or 'first-party'" ;;
esac

app_dir="${REPO_ROOT}/apps/${kind}/${app_name}"
catalog_file="${REPO_ROOT}/catalog.yaml"
var_name="$(printf '%s' "$app_name" | tr '[:lower:]-' '[:upper:]_')_VERSION"

if [[ -d "$app_dir" ]]; then
  die "apps/${kind}/${app_name}/ already exists — refusing to overwrite. Remove it manually first if you really want to re-scaffold."
fi

existing_count="$(yq eval "[.apps[] | select(.name == \"${app_name}\")] | length" "$catalog_file")"
if [[ "$existing_count" != "0" ]]; then
  die "catalog.yaml already has an entry named '${app_name}' — refusing to add a duplicate. Remove it manually first if you really want to re-scaffold."
fi

if [[ -z "$image_ref" ]]; then
  if [[ "$kind" == "first-party" ]]; then
    image_ref="ghcr.io/CHANGEME-org/${app_name}"
  else
    image_ref="CHANGEME-vendor/${app_name}"
  fi
fi

mkdir -p "$app_dir"

cat > "${app_dir}/compose.yaml" <<EOF
# apps/${kind}/${app_name}/compose.yaml — ${subdomain}.\${DOMAIN} (catalog.yaml: ${app_name})
#
# Scaffolded by scripts/new-app.sh — fill in the CHANGEME markers below:
#   - image reference and version pin
#   - healthcheck test command
#   - whether this app needs the shared Postgres / an OIDC client
#     (update catalog.yaml's needs_db / needs_oidc accordingly, and see
#     docs/adding-an-app.md for the full walkthrough)

services:
  ${app_name}:
    image: ${image_ref}:\${${var_name}:-CHANGEME}
    container_name: quarantine-${app_name}
    restart: unless-stopped
    profiles: [${app_name}]
    networks:
      - edge
    volumes:
      - ${app_name}-data:/data
    healthcheck:
      # CHANGEME: replace with a real check once the image is known.
      test: ["CMD", "true"]
      interval: 10s
      timeout: 5s
      retries: 5
    labels:
      - traefik.enable=true
      - traefik.http.routers.${app_name}.rule=Host(\`${subdomain}.\${DOMAIN}\`)
      - traefik.http.routers.${app_name}.entrypoints=websecure
      - traefik.http.routers.${app_name}.tls=true
      - traefik.http.services.${app_name}.loadbalancer.server.port=8080

networks:
  edge:
    external: true

volumes:
  ${app_name}-data:
EOF

yq eval -i "
  .apps += [{
    \"name\": \"${app_name}\",
    \"kind\": \"app\",
    \"compose_path\": \"apps/${kind}/${app_name}/compose.yaml\",
    \"subdomain\": \"${subdomain}\",
    \"needs_db\": false,
    \"needs_oidc\": false,
    \"notes\": \"CHANGEME: scaffolded by scripts/new-app.sh, not yet reviewed.\"
  }]
" "$catalog_file"

log "scaffolded apps/${kind}/${app_name}/compose.yaml"
log "appended a catalog.yaml entry for '${app_name}' — review and fill in every CHANGEME before use"
