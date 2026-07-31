#!/usr/bin/env bash
# provisioners/postgres.sh — idempotently ensure a database + role exist on
# the shared Postgres instance (decision 4).
#
# Usage: provisioners/postgres.sh <repo_root> <env> <plaintext_secrets_file> <name>
#   <name>  "zitadel" (core bootstrap) or a catalog.yaml app name (e.g. "uptime-kuma")
#
# Not app-specific: reads the target database/role name from <name> itself
# (hyphens -> underscores) and the password from the already-decrypted
# secrets file the caller passes in (see secrets_decrypt_to_tmpfs in
# lib/common.sh) — generating and persisting one via secrets_set if it's
# still a "CHANGEME..." placeholder or missing. Connects through the
# already-running postgres container's own psql via `docker exec`, so
# nothing beyond docker/yq/sops is required on the CLI host.
#
# Called directly for "zitadel" (its own db must exist before it can start
# — DSN mode doesn't auto-create it) and in a loop over catalog apps with
# needs_db: true (see bin/quarantine's cmd_start).

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT_SELF="$(cd -P "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT_SELF}/lib/common.sh"

require_bash4
require_cmd docker sops yq

if [[ $# -ne 4 ]]; then
  die "usage: provisioners/postgres.sh <repo_root> <env> <plaintext_secrets_file> <name>"
fi

repo_root="$1"
env="$2"
plaintext_file="$3"
name="$4"

[[ -f "$plaintext_file" ]] || die "plaintext secrets file not found: $plaintext_file"

# This script is documented above as directly invocable with a bare 4th
# argument, not only reached via bin/quarantine's now-validated
# `app add`/manifest path — so validate here too, independent of any
# caller-side gate, before `name` is used to build SQL role/database names.
[[ "$name" == "zitadel" || "$name" =~ ^[a-z][a-z0-9-]*$ ]] \
  || die "invalid name '${name}': lowercase letters, digits, hyphens only, must start with a letter"

# sql_escape <value> — doubles single quotes for safe embedding in a
# single-quoted SQL string literal. Values normally come from gen_password()
# (alphanumeric only, nothing to escape), but a restore-flow secrets file
# could contain operator-supplied passwords with arbitrary characters, so
# this is defensive, not decorative.
sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

# sql_ident <value> — doubles embedded double-quotes for safe embedding in a
# double-quoted SQL identifier (e.g. `"foo""bar"` for an identifier
# containing a literal `"`). Applied to db_role/db_name below, which
# ultimately derive from the `name` argument above.
sql_ident() {
  printf '%s' "$1" | sed 's/"/""/g'
}

db_role="$(printf '%s' "$name" | tr '-' '_')"
db_name="$db_role"

if [[ "$name" == "zitadel" ]]; then
  secret_key='.core.zitadel.db_password'
else
  secret_key=".apps[\"${name}\"].db_password"
fi

password="$(secrets_get "$plaintext_file" "$secret_key")"

if [[ -z "$password" || "$password" == CHANGEME* ]]; then
  log "generating a new Postgres password for '${name}' (${secret_key})"
  password="$(gen_password 32)"
  secrets_set "$repo_root" "$env" "$secret_key" "$password"
fi

postgres_container="quarantine-postgres"
admin_user="${POSTGRES_ADMIN_USER:-postgres}"

docker inspect "$postgres_container" >/dev/null 2>&1 \
  || die "postgres container not running: ${postgres_container} (must be healthy before provisioning)"

# Password goes through sql_escape (single-quote doubling, for the
# single-quoted literal it's embedded in). db_role/db_name go through BOTH
# sql_escape (for the `rolname = '...'` / `datname = '...'` literal
# comparisons) and sql_ident (for the double-quoted identifier positions,
# e.g. CREATE ROLE "..."). `name` is already gated by the regex check above,
# so today these can never actually contain a quote — but this script is
# documented as directly invocable with an unvalidated 4th argument, so the
# escaping stays as real defense in depth, not just decoration.
password_sql="$(sql_escape "$password")"
db_role_lit="$(sql_escape "$db_role")"
db_name_lit="$(sql_escape "$db_name")"
db_role_ident="\"$(sql_ident "$db_role")\""
db_name_ident="\"$(sql_ident "$db_name")\""

log "ensuring Postgres role + database for '${name}' (role=${db_role}, db=${db_name})"

# Output captured (not streamed live) and stdout/stderr merged: on failure,
# Postgres's own error diagnostics often quote the offending SQL line
# verbatim, including the plaintext password embedded in it — withheld by
# default rather than dumped into terminal scrollback/CI logs/journald,
# consistent with how this codebase otherwise goes out of its way to keep
# secrets off of anything but the tmpfs plaintext file.
sql_output=""
sql_ok=1
sql_output="$(docker exec -i "$postgres_container" psql -U "$admin_user" -d postgres -v ON_ERROR_STOP=1 2>&1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${db_role_lit}') THEN
    CREATE ROLE ${db_role_ident} LOGIN PASSWORD '${password_sql}';
  ELSE
    ALTER ROLE ${db_role_ident} WITH LOGIN PASSWORD '${password_sql}';
  END IF;
END
\$\$;

SELECT 'CREATE DATABASE ${db_name_ident} OWNER ${db_role_ident}'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${db_name_lit}')
\gexec

GRANT ALL PRIVILEGES ON DATABASE ${db_name_ident} TO ${db_role_ident};
SQL
)" || sql_ok=0

if (( sql_ok == 0 )); then
  if [[ -n "${QUARANTINE_DEBUG:-}" ]]; then
    printf '%s\n' "$sql_output" >&2
  fi
  die "failed to provision Postgres role/database for '${name}' (set QUARANTINE_DEBUG=1 and re-run to see full psql output — it may include the plaintext password)"
fi

log "Postgres role + database ready for '${name}'"
