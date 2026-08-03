#!/usr/bin/env bash
# infra/ci/github-runner/watchdog.sh — host-level safety net for when the CI
# runner container disappears entirely (an interrupted recreate killed the
# old one before a new one finished, a disk-full event, a host reboot) and
# nothing else would bring it back: quarantine start's own runner
# reconciliation needs a runner to execute FROM, so it can never repair a
# fully-missing runner on its own — chicken-and-egg. Run this from the HOST
# via the accompanying systemd .service/.timer units, never from inside a
# runner-executed job.
#
# Deliberately checks for ABSENCE before acting, not a blind periodic
# `up -d runner`: Compose has been observed wanting to recreate the runner
# (and other services) even with a byte-for-byte unchanged config (see
# platform#9/#10's PR discussion) — a blind periodic up -d could interrupt
# a healthy runner mid-job. This only touches anything when NO runner
# container is running at all.
set -euo pipefail

QUARANTINE_REPO="${QUARANTINE_REPO:-/opt/quarantine/repo}"
QUARANTINE_ENV="${QUARANTINE_ENV:-dev}"
project="quarantine-${QUARANTINE_ENV}"

running="$(docker ps \
  --filter "label=com.docker.compose.project=${project}" \
  --filter "label=com.docker.compose.service=runner" \
  --filter "status=running" \
  --format '{{.Names}}')"

if [[ -n "$running" ]]; then
  exit 0
fi

echo "$(date -Is) [runner-watchdog] no running runner container for '${project}' — bringing one up"
exec docker compose \
  --project-name "$project" \
  --env-file "${QUARANTINE_REPO}/environments/${QUARANTINE_ENV}/.env" \
  -f "${QUARANTINE_REPO}/environments/${QUARANTINE_ENV}/compose.yaml" \
  up -d runner
