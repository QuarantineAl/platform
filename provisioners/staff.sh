#!/usr/bin/env bash
# provisioners/staff.sh — the environment's staff allowlist.
#
# Run it through `quarantine staff ...` (bin/quarantine), which decrypts the
# secrets and resolves DOMAIN first, like `quarantine tenant ...`.
#
# WHY THIS EXISTS
#   Zitadel's login page lets anyone register (Wishora needs public sign-up),
#   and every app shares one Zitadel organization and project. So "signed in"
#   only means "has an account", not "works here". Every internal app behind
#   oauth2-proxy (shared Lazzaretto, n8n, docs, bem, delivery-note-ai,
#   uptime-kuma) admits only the emails in this one file.
#
# THE FILE
#   ${QUARANTINE_STAFF_FILE} (default /opt/quarantine/staff/authenticated-emails.txt),
#   one email per line. It lives outside the repo for the same reason tenant
#   allowlists do: it lists real people's addresses. Each oauth2-proxy watches
#   it, so add/remove take effect without a restart. A missing file fails
#   closed: the containers can't start. `quarantine start` creates an empty one.
#
#   The writes copy lazzaretto-tenant.sh's write_members(): rewrite in place
#   (Docker binds the inode, a rename would go unseen) and keep it 0644
#   (oauth2-proxy runs as uid 65532 and exits if it can't read the file).
#
# Usage:
#   staff.sh ensure <repo_root> <env> <secrets>
#   staff.sh add    <repo_root> <env> <secrets> <email>
#   staff.sh remove <repo_root> <env> <secrets> <email>
#   staff.sh list   <repo_root> <env> <secrets> [--json]

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT_SELF="$(cd -P "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT_SELF}/lib/common.sh"

require_bash4

VERB="${1:-}"
case "$VERB" in
  ensure|add|remove|list) shift ;;
  *) die "usage: provisioners/staff.sh ensure|add|remove|list <repo_root> <env> <secrets_file> [...]" ;;
esac

[[ $# -ge 3 ]] || die "usage: provisioners/staff.sh ${VERB} <repo_root> <env> <plaintext_secrets_file> [...]"
repo_root="$1" env="$2" plaintext_file="$3"; shift 3

email="" want_json=false
case "$VERB" in
  add|remove)
    [[ $# -eq 1 ]] || die "usage: quarantine staff ${VERB} <email>"
    # oauth2-proxy lowercases addresses on load and lookup; store them the
    # same way so `list` shows exactly what is enforced.
    email="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    [[ "$email" =~ ^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$ ]] || die "invalid email '$1'"
    ;;
  list)
    [[ $# -eq 0 || ( $# -eq 1 && "$1" == "--json" ) ]] || die "usage: quarantine staff list [--json]"
    [[ $# -eq 1 ]] && want_json=true
    ;;
  ensure)
    [[ $# -eq 0 ]] || die "usage: provisioners/staff.sh ensure <repo_root> <env> <secrets>"
    ;;
esac

STAFF_FILE="$QUARANTINE_STAFF_FILE"

read_staff() {
  [[ -f "$STAFF_FILE" ]] || return 0
  sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$STAFF_FILE" \
    | grep -v '^$' || true
}

ensure_file() {
  local dir
  dir="$(dirname "$STAFF_FILE")"
  mkdir -p "$dir"; chmod 755 "$dir"
  [[ -f "$STAFF_FILE" ]] || install -m 644 /dev/null "$STAFF_FILE"
  chmod 644 "$STAFF_FILE"
}

write_staff() {
  ensure_file
  : > "$STAFF_FILE"
  (( $# > 0 )) && printf '%s\n' "$@" >> "$STAFF_FILE"
  chmod 644 "$STAFF_FILE"
}

case "$VERB" in
  ensure)
    if [[ ! -f "$STAFF_FILE" ]]; then
      ensure_file
      warn "created an EMPTY staff allowlist at ${STAFF_FILE}: nobody can open the internal apps until you run 'quarantine staff add <email>'"
    else
      ensure_file
    fi
    ;;

  add)
    declare -a current=()
    while IFS= read -r line; do [[ -n "$line" ]] && current+=("$line"); done < <(read_staff)
    for m in "${current[@]}"; do
      if [[ "$m" == "$email" ]]; then
        log "'${email}' is already on the staff list — nothing to do"
        exit 0
      fi
    done
    current+=("$email")
    write_staff "${current[@]}"
    log "added '${email}' to the staff list (${#current[@]} people) — no restart needed"
    if [[ -z "$("${repo_root}/provisioners/zitadel.sh" user-show "$repo_root" "$env" "$plaintext_file" "$email" --json 2>/dev/null || true)" ]]; then
      warn "no Zitadel user exists for ${email} yet — create one: quarantine user add ${email} --invite"
    fi
    ;;

  remove)
    declare -a kept=()
    found=false
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      if [[ "$line" == "$email" ]]; then found=true; continue; fi
      kept+=("$line")
    done < <(read_staff)
    if [[ "$found" != true ]]; then
      log "'${email}' is not on the staff list — nothing to do"
      exit 0
    fi
    write_staff "${kept[@]}"
    log "removed '${email}' from the staff list — the internal apps refuse them from their next request"
    ;;

  list)
    if [[ "$want_json" == true ]]; then
      out="[" first=true
      while IFS= read -r line; do
        [[ "$first" == true ]] || out+=","
        first=false
        out+="\"${line}\""
      done < <(read_staff)
      printf '{"file":"%s","staff":%s]}\n' "$STAFF_FILE" "$out"
    else
      read_staff
    fi
    ;;
esac
