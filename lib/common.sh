#!/usr/bin/env bash
# lib/common.sh — shared helpers for the quarantine CLI and provisioners.
#
# This file is sourced, never executed directly. Callers are expected to run
# under `set -euo pipefail`. It provides:
#   - log/warn/die output helpers
#   - command/dependency checks
#   - a yq wrapper (requires mikefarah/yq v4, the Go rewrite — NOT the Python
#     kislyuk/yq wrapper, which uses a different expression syntax)
#   - a sops wrapper that decrypts environment secrets to tmpfs and registers
#     an EXIT trap to wipe the plaintext
#   - a single docker compose wrapper that pins --project-name and --env-file
#   - health-gating via `docker inspect`
#   - manifest.yaml -> <APP>_VERSION env export
#   - best-effort DNS verification
#
# Nothing in here is app-specific. Catalog/app knowledge lives in catalog.yaml
# and is read by callers, not by this file.

if [[ -n "${QUARANTINE_LIB_COMMON_SOURCED:-}" ]]; then
  # shellcheck disable=SC2317 # exit is the fallback if this file is ever run directly instead of sourced
  return 0 2>/dev/null || exit 0
fi
QUARANTINE_LIB_COMMON_SOURCED=1

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

_q_color() { [[ -t 2 ]] && printf '\033[%sm' "$1" || true; }
_q_reset() { [[ -t 2 ]] && printf '\033[0m' || true; }

log() {
  printf '%s[quarantine]%s %s\n' "$(_q_color 36)" "$(_q_reset)" "$*" >&2
}

warn() {
  printf '%s[quarantine] WARN:%s %s\n' "$(_q_color 33)" "$(_q_reset)" "$*" >&2
}

die() {
  printf '%s[quarantine] ERROR:%s %s\n' "$(_q_color 31)" "$(_q_reset)" "$*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------

# require_cmd cmd [cmd...] — die listing every missing command at once,
# rather than failing on the first one.
require_cmd() {
  local missing=() c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if (( ${#missing[@]} > 0 )); then
    die "missing required command(s): ${missing[*]}"
  fi
}

# require_bash4 — the CLI relies on associative arrays and other bash 4+
# features; macOS ships bash 3.2, so fail loudly rather than break subtly.
# Specifically >= 4.4: earlier 4.x releases can treat `"${empty_array[@]}"`
# under `set -u` as an unbound-variable error instead of expanding to zero
# words, which this codebase relies on (e.g. iterating an empty
# active-apps list) without an `:-` fallback (a fallback which itself has
# its own inconsistent empty-vs-unset behavior across bash versions).
require_bash4() {
  if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    die "bash >= 4.4 is required (found ${BASH_VERSION}). On macOS: brew install bash."
  fi
}

# ---------------------------------------------------------------------------
# Generic trap accumulation (bash's `trap` overwrites; this appends)
# ---------------------------------------------------------------------------
# Backed by an explicit array, NOT by reading back `trap -p EXIT`'s own
# serialized text and re-quoting it: `trap -p` represents embedded single
# quotes as the '\'' escape sequence so its output can round-trip through
# `eval`, but a naive `s/^trap -- '(.*)' EXIT$/\1/` extraction (the
# previous approach) can't tell that escape sequence apart from the
# surrounding quoting — every additional trap_add call re-wraps the
# previous, already-escaped text in one more layer of quoting, and by the
# second call in the same process the result is unbalanced quotes that
# fail at EXIT time with "unexpected EOF while looking for matching `''"
# (reproduced empirically: harmless with exactly one trap_add call in a
# process, breaks the instant a second one is added — which
# generate_env_file's own trap_add, stacking on top of cmd_start's, now
# does on every `quarantine start`). An array sidesteps the round-trip
# entirely: each hook is stored as its own array element (exact string, no
# re-quoting involved) and a single fixed trap command iterates the array.
declare -a _QUARANTINE_EXIT_HOOKS=()

_quarantine_run_exit_hooks() {
  local hook
  for hook in "${_QUARANTINE_EXIT_HOOKS[@]}"; do
    eval "$hook"
  done
}

trap_add() {
  _QUARANTINE_EXIT_HOOKS+=("$1")
  trap _quarantine_run_exit_hooks EXIT
}

# ---------------------------------------------------------------------------
# yq wrapper (mikefarah/yq v4)
# ---------------------------------------------------------------------------

yq_get() {
  # yq_get <file> <expr> — prints the evaluated value, or "" if null/missing.
  local file="$1" expr="$2" val
  val="$(yq eval "$expr" "$file")"
  [[ "$val" == "null" ]] && val=""
  printf '%s' "$val"
}

yq_set_inplace() {
  # yq_set_inplace <file> <expr> <value> — sets a scalar value in place.
  local file="$1" expr="$2" value="$3"
  yq eval -i "${expr} = \"${value}\"" "$file"
}

# manifest_export_versions <manifest.yaml>
# Reads `apps: [{name, version}, ...]` and exports <APP>_VERSION for each,
# e.g. name "uptime-kuma" -> UPTIME_KUMA_VERSION. Used by `quarantine start`
# before invoking compose so image tags resolve from the manifest.
manifest_export_versions() {
  local manifest="$1" count i name version varname
  [[ -f "$manifest" ]] || die "manifest not found: $manifest"
  count="$(yq eval '.apps | length' "$manifest")"
  for (( i = 0; i < count; i++ )); do
    name="$(yq eval ".apps[$i].name" "$manifest")"
    version="$(yq eval ".apps[$i].version" "$manifest")"
    [[ -z "$name" || "$name" == "null" ]] && continue
    # No version pinned in the manifest -> don't export anything, so the
    # compose fragment's own ${APP_VERSION:-default} applies. Exporting the
    # literal string "null" here would override that default with an
    # invalid image tag.
    [[ -z "$version" || "$version" == "null" ]] && continue
    varname="$(printf '%s' "$name" | tr '[:lower:]-' '[:upper:]_')_VERSION"
    export "${varname}=${version}"
  done
}

# ---------------------------------------------------------------------------
# Secrets (SOPS + age)
# ---------------------------------------------------------------------------
# Convention:
#   - encrypted secrets live in git at environments/<env>/secrets.sops.yaml
#   - the age private key for that environment lives OUTSIDE the repo, at
#     /opt/quarantine/keys/age-<env>.txt (never committed, host-local, plus
#     whatever offline backup the operator keeps per docs/client-install.md)
#   - plaintext is only ever written to a tmpfs-backed tempfile, and is wiped
#     via an EXIT trap the instant the caller is done with it.

QUARANTINE_KEYS_DIR="${QUARANTINE_KEYS_DIR:-/opt/quarantine/keys}"

age_key_path() {
  local env="$1"
  printf '%s/age-%s.txt' "$QUARANTINE_KEYS_DIR" "$env"
}

secrets_file_path() {
  local repo_root="$1" env="$2"
  printf '%s/environments/%s/secrets.sops.yaml' "$repo_root" "$env"
}

# shred_file <path> — best-effort secure delete; falls back to overwrite+rm
# on systems without `shred` (e.g. macOS).
shred_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  if command -v shred >/dev/null 2>&1; then
    shred -u "$f" 2>/dev/null || rm -f "$f"
  else
    local size
    size="$(wc -c < "$f" 2>/dev/null || echo 0)"
    dd if=/dev/urandom of="$f" bs=1024 count=$(( (size / 1024) + 1 )) conv=notrunc >/dev/null 2>&1 || true
    rm -f "$f"
  fi
}

# secrets_decrypt_to_tmpfs <repo_root> <env>
# Decrypts the environment's secrets file to a 0600 tempfile on tmpfs
# (falls back to the platform tempdir if tmpfs isn't available, e.g. macOS
# dev) and prints the tempfile path on stdout.
#
# Does NOT register its own cleanup trap: callers almost always capture
# the path via `plaintext="$(secrets_decrypt_to_tmpfs ...)"`, and command
# substitution runs in a subshell — a trap registered inside this function
# would fire the instant that subshell exits (i.e. immediately after this
# function returns), shredding the file before the caller ever reads it.
# Callers MUST register their own cleanup right after capturing the path:
#   plaintext="$(secrets_decrypt_to_tmpfs "$repo_root" "$env")"
#   trap_add "shred_file '${plaintext}'"
secrets_decrypt_to_tmpfs() {
  local repo_root="$1" env="$2"
  local enc_file age_key tmp_dir tmp
  enc_file="$(secrets_file_path "$repo_root" "$env")"
  age_key="$(age_key_path "$env")"

  [[ -f "$enc_file" ]] || die "no secrets file for environment '$env': $enc_file"
  [[ -f "$age_key" ]] || die "age key not found for environment '$env': $age_key (see docs/client-install.md — restore or generate one with 'quarantine init')"

  tmp_dir="/dev/shm"
  [[ -d "$tmp_dir" && -w "$tmp_dir" ]] || tmp_dir="${TMPDIR:-/tmp}"
  tmp="$(mktemp "${tmp_dir%/}/quarantine-secrets.XXXXXX")"
  chmod 600 "$tmp"

  if ! SOPS_AGE_KEY_FILE="$age_key" sops --decrypt "$enc_file" > "$tmp" 2>/dev/null; then
    shred_file "$tmp"
    die "failed to decrypt secrets for '$env' (check age key at $age_key)"
  fi

  printf '%s' "$tmp"
}

# secrets_edit <repo_root> <env> — interactive edit-in-place via sops (used
# by provisioners to write back generated values, e.g. OIDC client secrets).
secrets_edit() {
  local repo_root="$1" env="$2" enc_file age_key
  enc_file="$(secrets_file_path "$repo_root" "$env")"
  age_key="$(age_key_path "$env")"
  [[ -f "$age_key" ]] || die "age key not found for environment '$env': $age_key"
  SOPS_AGE_KEY_FILE="$age_key" sops "$enc_file"
}

# _json_escape_string <value> — minimal JSON string-body escaping (backslash
# and double-quote, in that order, plus newline/tab for good measure).
# Used only to build the VALUE half of `sops --set PATH VALUE`, which sops
# parses as a JSON scalar — without this, a value containing a literal `"`
# breaks out of the intended string and can corrupt or redirect the write.
_json_escape_string() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# secrets_set <repo_root> <env> <yaml-path> <value>
# Idempotently writes one key into the encrypted secrets file without
# opening an interactive editor. Used by provisioners after generating a
# password or OIDC client secret. <value> is JSON-string-escaped before
# being embedded in sops's own "PATH VALUE" argument syntax — today's
# callers only ever pass gen_password()-style alphanumeric output, but
# provisioners/zitadel.sh passes OIDC client secrets and a provisioner PAT
# returned verbatim by Zitadel's own API, which are not guaranteed to avoid
# a literal double-quote.
#
# <yaml-path> uses the same dotted/yq-style syntax as every other function
# here that takes a "key" (e.g. `.apps["uptime-kuma"].oidc_client_secret`) —
# but `sops --set` itself requires bracket-path syntax
# (`["apps"]["uptime-kuma"]["oidc_client_secret"]`) and rejects the dotted
# form outright ("Invalid --set format", verified empirically). Converting
# through yq's own `path` operator (which decomposes any such expression
# into its segments, regardless of which of the two syntaxes was used to
# write it) means callers never need to know or care about sops's
# different path syntax.
secrets_set() {
  local repo_root="$1" env="$2" key="$3" value="$4" enc_file age_key value_json sops_path seg
  enc_file="$(secrets_file_path "$repo_root" "$env")"
  age_key="$(age_key_path "$env")"
  [[ -f "$age_key" ]] || die "age key not found for environment '$env': $age_key"

  sops_path=""
  while IFS= read -r seg; do
    sops_path+="[\"${seg//\"/\\\"}\"]"
  done < <(yq eval "${key} | path | .[]" -n)
  [[ -n "$sops_path" ]] || die "could not resolve a sops path for key '${key}'"

  value_json="\"$(_json_escape_string "$value")\""
  SOPS_AGE_KEY_FILE="$age_key" sops --set "${sops_path} ${value_json}" "$enc_file" >/dev/null
}

# secrets_get <plaintext_file> <yaml-path> — read one key out of an already
# decrypted plaintext file (from secrets_decrypt_to_tmpfs).
secrets_get() {
  local plaintext_file="$1" key="$2"
  yq_get "$plaintext_file" "$key"
}

# ---------------------------------------------------------------------------
# Docker Compose wrapper
# ---------------------------------------------------------------------------
# Every compose invocation in this repo MUST go through this function so
# --project-name and --env-file are always consistent. Never call
# `docker compose` directly from the CLI or provisioners.

qcompose() {
  local env="$1"; shift
  local repo_root="${QUARANTINE_REPO:?QUARANTINE_REPO must be set}"
  local compose_file="${repo_root}/environments/${env}/compose.yaml"
  local env_file="${repo_root}/environments/${env}/.env"

  [[ -f "$compose_file" ]] || die "no compose.yaml for environment '$env': $compose_file"
  [[ -f "$env_file" ]] || die "no .env for environment '$env': $env_file"

  docker compose \
    --project-name "quarantine-${env}" \
    --env-file "$env_file" \
    -f "$compose_file" \
    "$@"
}

# ---------------------------------------------------------------------------
# Health gating
# ---------------------------------------------------------------------------

# wait_healthy <container_name> [timeout_seconds=120] [interval_seconds=2]
# Polls `docker inspect` health status. Containers without a HEALTHCHECK are
# accepted as soon as they're Running (there's nothing else to wait on).
wait_healthy() {
  local container="$1" timeout="${2:-120}" interval="${3:-2}" waited=0 status

  log "waiting for ${container} to become healthy (timeout ${timeout}s)..."
  while (( waited < timeout )); do
    if ! docker inspect "$container" >/dev/null 2>&1; then
      sleep "$interval"; waited=$(( waited + interval )); continue
    fi

    # A second, separate `docker inspect` — guarded the same way as the
    # existence check above, not a bare assignment: the container can
    # disappear between the two calls (crash-loop, or a concurrent
    # `destroy`/`docker rm -f`), and under `set -e` an unguarded assignment
    # would abort the whole CLI instead of just treating it as "not yet
    # healthy, keep polling."
    if ! status="$(docker inspect --format \
      '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{if .State.Running}}running{{else}}stopped{{end}}{{end}}' \
      "$container" 2>/dev/null)"; then
      sleep "$interval"; waited=$(( waited + interval )); continue
    fi

    case "$status" in
      healthy|running) log "${container} is ${status}"; return 0 ;;
      stopped) die "${container} exited before becoming healthy — check: docker logs ${container}" ;;
      *) : ;; # starting/unhealthy — keep polling
    esac

    sleep "$interval"
    waited=$(( waited + interval ))
  done

  die "timed out after ${timeout}s waiting for ${container} to be healthy — check: docker logs ${container}"
}

# ---------------------------------------------------------------------------
# DNS verification (advisory only — never blocks `quarantine init`/`start`)
# ---------------------------------------------------------------------------

# resolve_public_ip — best-effort discovery of this host's public IP, for
# printing the A record the operator needs to create.
resolve_public_ip() {
  curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null \
    || curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null \
    || true
}

# check_dns <fqdn> <expected_ip> — warns (does not fail) if the fqdn doesn't
# resolve, or resolves to something other than expected_ip. TLS degrades to
# self-signed until ACME succeeds; this check never blocks init/start.
check_dns() {
  local fqdn="$1" expected_ip="$2" resolved=""

  if command -v dig >/dev/null 2>&1; then
    resolved="$(dig +short "$fqdn" A 2>/dev/null | tail -n1)"
  elif command -v host >/dev/null 2>&1; then
    resolved="$(host -t A "$fqdn" 2>/dev/null | awk '/has address/{print $NF; exit}')"
  elif command -v getent >/dev/null 2>&1; then
    resolved="$(getent ahostsv4 "$fqdn" 2>/dev/null | awk '{print $1; exit}')"
  fi

  if [[ -z "$resolved" ]]; then
    warn "DNS not configured for ${fqdn} — create an A record: ${fqdn} -> ${expected_ip}"
    return 1
  fi
  if [[ -n "$expected_ip" && "$resolved" != "$expected_ip" ]]; then
    warn "DNS for ${fqdn} resolves to ${resolved}, expected ${expected_ip} — update the A record: ${fqdn} -> ${expected_ip}"
    return 1
  fi

  log "DNS OK: ${fqdn} -> ${resolved}"
  return 0
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------

# acquire_lock <repo_root> <env> — exclusive, whole-process-lifetime lock
# over one environment's mutable state (manifest.yaml, secrets.sops.yaml).
# Nothing in this codebase otherwise guards those read-modify-write cycles,
# so two concurrent invocations (a stray double-run, a cron overlap, two
# operators) can silently lose-update each other. Held for the life of the
# calling process; never explicitly released — the kernel drops the flock
# the instant the holding process's fd closes, for any reason, including a
# crash, so there is no "stale lock file" state to clean up.
acquire_lock() {
  local repo_root="$1" env="$2" lock_dir lock_file lock_fd
  lock_dir="${repo_root}/.quarantine-locks"
  mkdir -p "$lock_dir"
  lock_file="${lock_dir}/${env}.lock"
  exec {lock_fd}>"$lock_file"
  flock -n "$lock_fd" \
    || die "another quarantine operation is already running for environment '${env}' — wait for it to finish, then retry"
}

# confirm_typed <prompt> <expected_word> — used by `quarantine destroy`.
confirm_typed() {
  local prompt="$1" expected="$2" input=""
  read -r -p "${prompt} (type '${expected}' to confirm): " input || true
  [[ "$input" == "$expected" ]]
}

# urlencode <value> — percent-encodes for safe embedding in one URI
# component (e.g. a Postgres DSN's password segment). gen_password()'s own
# output never needs this (plain alphanumeric), but a restore-flow secrets
# file can hold an operator-supplied password with delimiter characters
# (@, :, /, #) that would otherwise be misparsed as DSN structure.
urlencode() {
  local value="$1" out="" c i
  for (( i = 0; i < ${#value}; i++ )); do
    c="${value:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) out+="$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$out"
}

# gen_password [length=32] — random alphanumeric, safe for env files / URLs.
gen_password() {
  local length="${1:-32}"
  # Process substitution, not a `tr | head -c` pipe: with `set -o
  # pipefail` (every caller runs under `set -euo pipefail`), `head -c`
  # exiting after reading exactly $length bytes races with `tr` still
  # trying to write more from the infinite /dev/urandom stream — `tr`
  # can get SIGPIPE'd (exit 141), and pipefail reports that as the whole
  # pipeline's failure even though `head` produced the correct output.
  # This is racy (buffer-timing dependent), not consistently reproducible.
  # `head -c N < <(...)` is a single simple command with an input
  # redirection, not a pipeline — pipefail doesn't apply, and the process
  # substitution's own exit status is never checked by the parent shell.
  head -c "$length" < <(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom)
}

# gen_password_complex [length=32] — like gen_password, but guarantees at
# least one uppercase letter, one lowercase letter, one digit, and one
# symbol (from a small curated set that's safe embedded in a Postgres SQL
# string, a URI, a shell-free .env value, or JSON — no quotes, @, :, /, ?,
# #, $, backslash). For credentials actually checked against a password
# complexity policy — currently only Zitadel's first-instance admin user
# (ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD), which its default policy
# rejects for lacking a symbol if generated via plain gen_password().
# Everything else (DB passwords, etc.) should stay on gen_password(): e.g.
# Immich's own docs require its DB password be plain alphanumeric.
gen_password_complex() {
  local length="${1:-32}"
  # "-" must be LAST in a `tr` character class, never in the middle — tr
  # treats a mid-string "-" as a range operator (e.g. "*-_" silently
  # expanded into every ASCII char between '*' and '_', including ".",
  # digits, and uppercase letters — nothing like the intended symbol set).
  local symbols='!%^&*_=+-'
  local base sym upper lower digit
  # Full-length random base (not length-4): the 4 required characters are
  # spliced into random positions below rather than prepended in a fixed
  # order, so the result isn't predictably "symbol, upper, lower, digit,
  # then alphanumeric" to anyone who reads this function.
  base="$(head -c "$length" < <(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom))"
  sym="$(head -c 1 < <(LC_ALL=C tr -dc "$symbols" < /dev/urandom))"
  upper="$(head -c 1 < <(LC_ALL=C tr -dc 'A-Z' < /dev/urandom))"
  lower="$(head -c 1 < <(LC_ALL=C tr -dc 'a-z' < /dev/urandom))"
  digit="$(head -c 1 < <(LC_ALL=C tr -dc '0-9' < /dev/urandom))"

  local -a chars=("$sym" "$upper" "$lower" "$digit")
  local -a positions=()
  local p dup existing
  while (( ${#positions[@]} < 4 )); do
    p=$(( RANDOM % length ))
    dup=0
    for existing in "${positions[@]}"; do
      [[ "$existing" == "$p" ]] && dup=1 && break
    done
    (( dup == 0 )) && positions+=("$p")
  done

  local i
  for i in "${!positions[@]}"; do
    p="${positions[$i]}"
    base="${base:0:p}${chars[$i]}${base:$((p + 1))}"
  done

  printf '%s' "$base"
}
