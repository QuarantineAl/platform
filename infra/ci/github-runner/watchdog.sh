#!/usr/bin/env bash
# infra/ci/github-runner/watchdog.sh — host-level safety net for when a
# container that's part of the environment's CURRENT desired state
# disappears entirely (an interrupted recreate killed the old one before a
# new one finished, a disk-full event, a host reboot) and nothing else
# would bring it back. Started as a runner-only check, but the same
# interrupted-recreate failure mode can take out ANY service caught in the
# same event — traefik, signoz-keeper, and signoz-ingester were all hit
# alongside the runner in one real incident (see git history around
# platform#9/#10) — so this checks every service `quarantine start`
# currently considers active, not just the runner.
#
# Run this from the HOST via the accompanying systemd .service/.timer
# units, never from inside a runner-executed job — quarantine start's own
# reconciliation needs a runner to execute FROM, so it can never repair a
# fully-missing runner (or anything else) on its own.
#
# Deliberately checks for total ABSENCE (zero containers, running or
# stopped) rather than "not currently running": a deliberately
# decommissioned app (removed from manifest.yaml, then `quarantine start`
# stops it via `docker compose stop`) is intentionally left
# stopped-but-present forever — that's quarantine's own domain, not
# something this watchdog should undo. Only a container that's gone
# entirely, despite its service still being part of current desired
# state, counts as "stuck" here. This also means it only ever brings up
# services that are ALREADY missing — never touches a running container,
# so it can't interrupt a healthy one mid-job the way a blind periodic
# `up -d` would (Compose has been observed wanting to recreate services
# even with a byte-for-byte unchanged config — see platform#9/#10's PR
# discussion, never fully root-caused).
set -euo pipefail

QUARANTINE_REPO="${QUARANTINE_REPO:-/opt/quarantine/repo}"
QUARANTINE_CONFIG_FILE="${QUARANTINE_CONFIG_FILE:-/opt/quarantine/quarantine.yaml}"

# shellcheck source=../../lib/common.sh
source "${QUARANTINE_REPO}/lib/common.sh"

QUARANTINE_ENV="$(yq_get "$QUARANTINE_CONFIG_FILE" '.env')"
manifest="${QUARANTINE_REPO}/environments/${QUARANTINE_ENV}/manifest.yaml"
project="quarantine-${QUARANTINE_ENV}"

# Same exclusive lock cmd_start/cmd_app_add hold: without it, a watchdog
# tick landing while a real deploy is mid-flight could race a second
# `docker compose up -d` against the one already running — the same class
# of interrupted-operation mess that left orphaned containers behind
# earlier (see git history). Non-blocking (acquire_lock's own behavior):
# if another quarantine operation already holds it, this dies with a clear
# message and a non-zero exit — a normal, expected "skip, try again in two
# minutes" outcome for a timer-triggered oneshot, not a real failure.
acquire_lock "$QUARANTINE_REPO" "$QUARANTINE_ENV"

# Mirrors bin/quarantine's own profile_services (not exposed by
# lib/common.sh, so duplicated here rather than sourcing the whole CLI
# file — that file unconditionally runs its own command dispatch at the
# bottom, unsafe to source).
profile_services() {
  local profile="$1"
  comm -13 \
    <(qcompose "$QUARANTINE_ENV" config --services 2>/dev/null | sort -u) \
    <(qcompose "$QUARANTINE_ENV" --profile "$profile" config --services 2>/dev/null | sort -u)
}

declare -A want=()        # service name -> 1
declare -A svc_profile=() # service name -> --profile flag it needs (unset for the always-on baseline)

add_profile() {
  local profile="$1" svc
  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    want["$svc"]=1
    svc_profile["$svc"]="$profile"
  done < <(profile_services "$profile")
}

# Always-on baseline: traefik/postgres/zitadel/the runner itself — whatever
# cmd_start starts unconditionally, with no profile flag.
while IFS= read -r svc; do
  [[ -n "$svc" ]] && want["$svc"]=1
done < <(qcompose "$QUARANTINE_ENV" config --services 2>/dev/null)

add_profile observability

app_count="$(yq eval '.apps | length' "$manifest")"
for (( i = 0; i < app_count; i++ )); do
  app_name="$(yq eval ".apps[$i].name" "$manifest")"
  [[ -z "$app_name" || "$app_name" == "null" ]] && continue
  add_profile "$app_name"
done

missing=()
declare -A needed_profiles=()
for svc in "${!want[@]}"; do
  exists="$(docker ps -a \
    --filter "label=com.docker.compose.project=${project}" \
    --filter "label=com.docker.compose.service=${svc}" \
    --format '{{.Names}}')"
  [[ -n "$exists" ]] && continue
  missing+=("$svc")
  p="${svc_profile[$svc]:-}"
  [[ -n "$p" ]] && needed_profiles["$p"]=1
done

if (( ${#missing[@]} == 0 )); then
  exit 0
fi

profile_flags=()
for p in "${!needed_profiles[@]}"; do
  profile_flags+=(--profile "$p")
done

echo "$(date -Is) [watchdog] missing container(s) for: ${missing[*]} — bringing them up"
qcompose "$QUARANTINE_ENV" "${profile_flags[@]}" up -d "${missing[@]}"
