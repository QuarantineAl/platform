#!/usr/bin/env bash
# provisioners/garage.sh — make sure an app has its own Garage bucket and
# access key. Safe to run on every `quarantine start`.
#
# Usage: provisioners/garage.sh <repo_root> <env> <plaintext_secrets_file> <name>
#   <name>  a catalog.yaml app with needs_bucket: true
#
# The bucket is named after the app. The key is generated here (not by
# Garage) and stored in secrets.sops.yaml under .apps[<name>], then
# imported into Garage. Because the key lives in our secrets, a Garage
# rebuilt from empty volumes gets the same key back and apps keep working.
#
# Garage must already be running and healthy (reconcile_apps in
# bin/quarantine starts it first).

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT_SELF="$(cd -P "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT_SELF}/lib/common.sh"

require_bash4
require_cmd docker sops yq

if [[ $# -ne 4 ]]; then
  die "usage: provisioners/garage.sh <repo_root> <env> <plaintext_secrets_file> <name>"
fi

repo_root="$1"
env="$2"
plaintext_file="$3"
name="$4"

[[ -f "$plaintext_file" ]] || die "plaintext secrets file not found: $plaintext_file"

# Same app-name rule as everywhere else, plus S3's 3-63 character limit,
# since the bucket is named after the app.
[[ "$name" =~ ^[a-z][a-z0-9-]{2,62}$ ]] \
  || die "invalid name '${name}': 3-63 chars, lowercase letters, digits, hyphens, starting with a letter"

garage_container="quarantine-garage"
docker inspect "$garage_container" >/dev/null 2>&1 \
  || die "garage container not running: ${garage_container} (add 'garage' to this environment's manifest)"

# garage <args...> — run the Garage CLI in the container. Output is kept
# off the terminal unless QUARANTINE_DEBUG is set.
garage() {
  if [[ -n "${QUARANTINE_DEBUG:-}" ]]; then
    docker exec "$garage_container" /garage "$@"
  else
    docker exec "$garage_container" /garage "$@" >/dev/null 2>&1
  fi
}

id_path=".apps[\"${name}\"].s3_access_key_id"
secret_path=".apps[\"${name}\"].s3_secret_access_key"

key_id="$(secrets_get "$plaintext_file" "$id_path")"
key_secret="$(secrets_get "$plaintext_file" "$secret_path")"

if [[ -z "$key_id" || "$key_id" == CHANGEME* || -z "$key_secret" || "$key_secret" == CHANGEME* ]]; then
  log "generating a new S3 access key for '${name}'"
  # Garage's own format: "GK" + 24 hex chars, and a 64-hex-char secret.
  key_id="GK$(gen_hex 12)"
  key_secret="$(gen_hex 32)"
  secrets_set "$repo_root" "$env" "$id_path" "$key_id"
  secrets_set "$repo_root" "$env" "$secret_path" "$key_secret"
  log "secrets.sops.yaml was updated — remember to git add/commit/push environments/${env}/secrets.sops.yaml"
fi

log "ensuring Garage bucket + key for '${name}'"

if ! garage key info "$key_id"; then
  # The secret is briefly visible in this host's process list while the
  # import runs. Garage's CLI has no stdin option for it.
  garage key import -n "quarantine-${name}" --yes "$key_id" "$key_secret" \
    || die "could not import S3 key ${key_id} for '${name}'. Garage refuses to re-import a key ID that was ever deleted; delete ${id_path} and ${secret_path} from secrets.sops.yaml (sops, see docs/site/guides/secrets.md) to get a new one"
fi

if ! garage bucket info "$name"; then
  garage bucket create "$name" || die "could not create Garage bucket '${name}'"
fi

# Allowing again is a no-op, so this also repairs a key that lost access.
garage bucket allow --read --write --owner "$name" --key "$key_id" \
  || die "could not grant key ${key_id} access to bucket '${name}'"

log "Garage bucket + key ready for '${name}'"
