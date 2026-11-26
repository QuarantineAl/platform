#!/usr/bin/env bash
# provisioners/backup.sh — back up one environment's data, and get it back.
#
# Run it through `quarantine backup ...` (bin/quarantine), which decrypts the
# secrets first.
#
# WHAT A BACKUP HOLDS
#   - every named Docker volume on the host, except the ones listed in
#     DEFAULT_EXCLUDES below and in the host config
#   - a full dump of the shared Postgres (the raw postgres-data volume is
#     skipped: copying a running database's files gives a broken copy)
#   - a clean copy of every SQLite database found in those volumes, for the
#     same reason
#   - /opt/quarantine/tenants, /opt/quarantine/staff and quarantine.yaml
#
#   Not in it: the age key. The backup is encrypted with a password stored in
#   secrets.sops.yaml, and that file needs the age key to open. Keep the age
#   key somewhere off this host, or no backup can be read.
#
# HOW
#   restic (run from its Docker image, nothing to install) encrypts the data
#   on this host and sends it to the repository. Only changed data is sent,
#   so nightly runs are small.
#
# CONFIG (host config, /opt/quarantine/quarantine.yaml)
#   backup:
#     repository: rest:http://10.0.0.1:8000/prod   # or sftp:..., or a local path
#     keep_daily: 7                # optional, these three are the defaults
#     keep_weekly: 4
#     keep_monthly: 0
#     ping_url: https://...        # optional, fetched after each good run
#     exclude_volumes: ["pr-*"]    # optional, shell patterns
#
# Usage:
#   backup.sh init           <repo_root> <env> <secrets> <repository>
#   backup.sh run            <repo_root> <env> <secrets>
#   backup.sh list           <repo_root> <env> <secrets>
#   backup.sh status         <repo_root> <env> <secrets>
#   backup.sh restore        <repo_root> <env> <secrets> <snapshot> <dir>
#   backup.sh restore-volume <repo_root> <env> <secrets> <snapshot> <volume>

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT_SELF="$(cd -P "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT_SELF}/lib/common.sh"

require_bash4
require_cmd docker sops yq

# Image pins. restic does the backup; python is only used for its built-in
# SQLite library.
RESTIC_IMAGE="${QUARANTINE_RESTIC_IMAGE:-restic/restic:0.20.0}"
SQLITE_IMAGE="${QUARANTINE_SQLITE_IMAGE:-python:3.13-alpine}"

# How many backups to keep, unless the host config says otherwise
# (backup.keep_daily / keep_weekly / keep_monthly). Each backup only stores
# what changed since the one before, so these cost little space.
declare -A DEFAULT_KEEP=([daily]=7 [weekly]=4 [monthly]=0)

# Volumes never backed up as raw files: Postgres is dumped instead, SigNoz is
# telemetry we can lose, and the last one is restic's own cache.
DEFAULT_EXCLUDES=('*_postgres-data' '*signoz*' 'quarantine-restic-cache')

# A run older than this many hours makes `status` fail.
MAX_AGE_HOURS=26

[[ $# -ge 4 ]] || die "usage: provisioners/backup.sh <mode> <repo_root> <env> <plaintext_secrets_file> [args...]"
mode="$1"; repo_root="$2"; env="$3"; plaintext_file="$4"
shift 4

[[ -f "$plaintext_file" ]] || die "plaintext secrets file not found: $plaintext_file"

config_file="${QUARANTINE_CONFIG_FILE:-/opt/quarantine/quarantine.yaml}"
backup_dir="${QUARANTINE_BACKUP_DIR:-/opt/quarantine/backups}"
host_dir="${QUARANTINE_HOST_DIR:-/opt/quarantine}"
ssh_dir="${QUARANTINE_KEYS_DIR}/backup-ssh"
staging_dir="${backup_dir}/staging"
last_success_file="${backup_dir}/last-success"
postgres_container="${QUARANTINE_POSTGRES_CONTAINER:-quarantine-postgres}"

repository="$(yq_get "$config_file" '.backup.repository')"
password="$(secrets_get "$plaintext_file" '.core.backup.password')"
[[ "$password" == CHANGEME* ]] && password=""

# --- helpers ---------------------------------------------------------------

require_ready() {
  [[ -n "$repository" ]] || die "no backup repository configured — run 'quarantine backup init <repository>' first"
  [[ -n "$password" ]] || die "no backup password in secrets.sops.yaml — run 'quarantine backup init <repository>' first"
}

# restic [--mount <docker -v value>]... <restic args...>
# Runs restic in a container. The password travels as an environment
# variable, never on the command line.
restic() {
  local -a docker_args=(run --rm --network host --hostname "quarantine-${env}"
    -e RESTIC_PASSWORD -e RESTIC_REPOSITORY
    -v "quarantine-restic-cache:/root/.cache/restic")
  local repo_in_container="$repository"

  [[ -d "$ssh_dir" ]] && docker_args+=(-v "${ssh_dir}:/root/.ssh")
  # A repository that is a plain path lives on this host (a mounted disk).
  if [[ "$repository" == /* ]]; then
    docker_args+=(-v "${repository}:/repo")
    repo_in_container="/repo"
  fi
  while [[ "${1:-}" == "--mount" ]]; do
    docker_args+=(-v "$2"); shift 2
  done

  RESTIC_PASSWORD="$password" RESTIC_REPOSITORY="$repo_in_container" \
    docker "${docker_args[@]}" "$RESTIC_IMAGE" "$@"
}

# keep_args — prints restic's --keep-* flags, one word per line.
keep_args() {
  local kind value
  for kind in daily weekly monthly; do
    value="$(yq_get "$config_file" ".backup.keep_${kind}")"
    [[ -n "$value" ]] || value="${DEFAULT_KEEP[$kind]}"
    [[ "$value" =~ ^[0-9]+$ ]] || die "backup.keep_${kind} must be a number, got '${value}'"
    (( value > 0 )) && printf -- '--keep-%s\n%s\n' "$kind" "$value"
  done
  return 0
}

# volumes_to_back_up — one volume name per line.
volumes_to_back_up() {
  local -a excludes=("${DEFAULT_EXCLUDES[@]}")
  local pattern name skip
  while IFS= read -r pattern; do
    [[ -n "$pattern" ]] && excludes+=("$pattern")
  done < <(yq eval '.backup.exclude_volumes[]?' "$config_file" 2>/dev/null || true)

  local all
  all="$(docker volume ls --format '{{.Name}}' | sort)" || die "could not list Docker volumes"

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    # 64 hex characters is a volume nobody named: throwaway data.
    [[ "$name" =~ ^[0-9a-f]{64}$ ]] && continue
    skip=0
    for pattern in "${excludes[@]}"; do
      # shellcheck disable=SC2053  # pattern match is the point
      [[ "$name" == $pattern ]] && { skip=1; break; }
    done
    (( skip )) || printf '%s\n' "$name"
  done <<< "$all"
}

# latest_filter <snapshot> — prints the restic flags that make "latest" mean
# the newest COMPLETE backup of this environment. A run that could not dump
# Postgres is still saved, tagged "incomplete", and must not be picked here.
latest_filter() {
  if [[ "$1" == "latest" ]]; then
    printf -- '--tag\n%s,complete\n' "$env"
  fi
}

# The Python that copies SQLite databases. It finds them by file header, not
# by name, so an app does not have to declare anything.
SQLITE_COPY_SCRIPT='
import os, sqlite3, sys, urllib.parse

MAGIC = b"SQLite format 3\x00"
copied = failed = 0

def copy(src_path, dst_path):
    uri = "file:" + urllib.parse.quote(src_path)
    try:
        src = sqlite3.connect(uri + "?mode=ro", uri=True, timeout=60)
        src.execute("select count(*) from sqlite_master").fetchone()
    except sqlite3.Error:
        # A WAL database nobody has open cannot be opened read-only. With no
        # pending WAL file the main file is complete, so read it as-is.
        wal = src_path + "-wal"
        if os.path.exists(wal) and os.path.getsize(wal) > 0:
            raise
        src = sqlite3.connect(uri + "?immutable=1", uri=True)
    dst = sqlite3.connect(dst_path)
    src.backup(dst)
    result = dst.execute("pragma integrity_check").fetchone()[0]
    dst.close()
    src.close()
    if result != "ok":
        raise RuntimeError("integrity check: " + result)
    st = os.stat(src_path)
    os.chown(dst_path, st.st_uid, st.st_gid)
    os.chmod(dst_path, st.st_mode & 0o7777)

# Who owns the top directory of each volume. A restore into a new volume
# needs it: Docker creates that directory as root, and an app that runs as
# another user could then not write to it.
with open("/staging/volume-owners", "w") as fh:
    for vol in sorted(os.listdir("/volumes")):
        st = os.stat(os.path.join("/volumes", vol))
        fh.write("%s %d %d %o\n" % (vol, st.st_uid, st.st_gid, st.st_mode & 0o7777))

for root, _dirs, files in os.walk("/volumes"):
    for name in files:
        path = os.path.join(root, name)
        try:
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            with open(path, "rb") as fh:
                if fh.read(16) != MAGIC:
                    continue
        except OSError:
            continue
        rel = path[len("/volumes/"):]
        dst = os.path.join("/staging/sqlite", rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        try:
            copy(path, dst)
            copied += 1
            print("  sqlite ok   " + rel)
        except Exception as exc:
            failed += 1
            print("  sqlite FAIL " + rel + ": " + str(exc), file=sys.stderr)
            if os.path.exists(dst):
                os.remove(dst)

print("  %d SQLite database(s) copied, %d failed" % (copied, failed))
sys.exit(1 if failed else 0)
'

# --- init ------------------------------------------------------------------

do_init() {
  [[ $# -eq 1 ]] || die "usage: quarantine backup init <repository>   (e.g. rest:http://10.0.0.1:8000/${env}, sftp:backup@10.0.0.1:/srv/backups/${env}, or a local path)"
  local new_repo="$1"
  acquire_lock "$repo_root" "$env"

  mkdir -p "$backup_dir"
  chmod 700 "$backup_dir"

  if [[ -z "$password" ]]; then
    log "generating the backup password (.core.backup.password)"
    password="$(gen_password 48)"
    secrets_set "$repo_root" "$env" '.core.backup.password' "$password"
    warn "secrets.sops.yaml changed on this host — commit it through a PR before the next deploy"
  fi

  yq_set_inplace "$config_file" '.backup.repository' "$new_repo"
  repository="$new_repo"
  log "backup repository: ${repository}"

  if [[ "$repository" == sftp:* ]]; then
    require_cmd ssh-keygen
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    if [[ ! -f "${ssh_dir}/id_ed25519" ]]; then
      ssh-keygen -q -t ed25519 -N '' -C "quarantine-backup-${env}" -f "${ssh_dir}/id_ed25519"
      # First connection records the server's key; a different key later
      # is refused.
      printf 'Host *\n  StrictHostKeyChecking accept-new\n  BatchMode yes\n  ServerAliveInterval 60\n' > "${ssh_dir}/config"
      chmod 600 "${ssh_dir}/config"
    fi
    log "SSH public key for the backup server (add it to the backup user's authorized_keys):"
    cat "${ssh_dir}/id_ed25519.pub" >&2
  elif [[ "$repository" == /* ]]; then
    mkdir -p "$repository"
  fi

  if restic cat config >/dev/null 2>&1; then
    log "repository already exists and the password opens it"
  elif restic init >&2; then
    log "repository created"
  else
    warn "could not reach the repository yet — fix access, then run 'quarantine backup init ${repository}' again"
    return 0
  fi

  install_timer
}

# Nightly run through systemd. Skipped where there is no systemd (a laptop).
install_timer() {
  if [[ ! -d /run/systemd/system || "$(id -u)" != "0" ]]; then
    warn "no systemd here (or not root) — schedule 'quarantine backup run' yourself"
    return 0
  fi
  cat > /etc/systemd/system/quarantine-backup.service <<EOF
[Unit]
Description=quarantine backup (${env})
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
Environment=QUARANTINE_CONFIG_FILE=${config_file}
ExecStart=/usr/local/bin/quarantine backup run
EOF
  cat > /etc/systemd/system/quarantine-backup.timer <<'EOF'
[Unit]
Description=Nightly quarantine backup

[Timer]
OnCalendar=*-*-* 02:30:00
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now quarantine-backup.timer >/dev/null
  log "nightly backup scheduled (systemctl list-timers quarantine-backup.timer)"
}

# --- run -------------------------------------------------------------------

do_run() {
  require_ready
  acquire_lock "$repo_root" "${env}-backup"

  local failed=0 vol
  local -a volumes=() mounts=() paths=()

  rm -rf "$staging_dir"
  mkdir -p "$staging_dir/postgres" "$staging_dir/sqlite"
  chmod 700 "$backup_dir" "$staging_dir"
  # The staging copy holds plain data: never leave it behind.
  trap_add "rm -rf '${staging_dir}'"

  local vol_list
  vol_list="$(volumes_to_back_up)" || die "could not work out which volumes to back up"
  while IFS= read -r vol; do
    [[ -n "$vol" ]] && volumes+=("$vol")
  done <<< "$vol_list"
  log "backing up ${#volumes[@]} volume(s)"

  # 1. Postgres
  if docker inspect "$postgres_container" >/dev/null 2>&1; then
    log "dumping Postgres"
    if ! docker exec "$postgres_container" pg_dumpall -U "${POSTGRES_ADMIN_USER:-postgres}" --clean --if-exists \
        > "${staging_dir}/postgres/dumpall.sql"; then
      warn "Postgres dump failed"
      rm -f "${staging_dir}/postgres/dumpall.sql"
      failed=1
    fi
  else
    warn "no ${postgres_container} container — Postgres is NOT in this backup"
    failed=1
  fi

  # 2. SQLite databases. Mounted read-write on purpose: SQLite needs to
  # take its locks to read a database another process is writing.
  if (( ${#volumes[@]} > 0 )); then
    log "copying SQLite databases"
    local -a sqlite_mounts=()
    for vol in "${volumes[@]}"; do
      sqlite_mounts+=(-v "${vol}:/volumes/${vol}")
    done
    if ! docker run --rm -i "${sqlite_mounts[@]}" -v "${staging_dir}:/staging" \
        "$SQLITE_IMAGE" python - <<< "$SQLITE_COPY_SCRIPT" >&2; then
      warn "at least one SQLite database could not be copied cleanly"
      failed=1
    fi
  fi

  # 3. Everything goes to the repository in one snapshot.
  for vol in "${volumes[@]}"; do
    mounts+=(--mount "${vol}:/volumes/${vol}:ro")
    paths+=("/volumes/${vol}")
  done
  mounts+=(--mount "${staging_dir}:/staging:ro")
  paths+=(/staging)
  local item
  for item in tenants staff; do
    if [[ -d "${host_dir}/${item}" ]]; then
      mounts+=(--mount "${host_dir}/${item}:/host/${item}:ro")
      paths+=("/host/${item}")
    fi
  done
  mounts+=(--mount "${config_file}:/host/quarantine.yaml:ro")
  paths+=(/host/quarantine.yaml)

  log "uploading to ${repository}"
  local rc=0 state=complete
  (( failed )) && state=incomplete
  restic "${mounts[@]}" backup --tag "$env" --tag "$state" "${paths[@]}" >&2 || rc=$?
  # restic exits 3 when the backup was saved but some files could not be read.
  if (( rc == 3 )); then
    warn "some files could not be read — the backup is saved without them"
    failed=1
    restic tag --tag "${env},complete" --remove complete --add incomplete latest >&2 \
      || warn "could not mark that backup as incomplete"
  elif (( rc != 0 )); then
    die "upload failed — nothing new was saved"
  fi

  log "removing old backups"
  # Only complete backups count towards what is kept. Otherwise a broken
  # run could push out the good backup from the same day.
  local keep_list
  local -a keep=()
  keep_list="$(keep_args)" || die "invalid backup retention settings"
  mapfile -t keep <<< "$keep_list"
  (( ${#keep[@]} >= 2 )) || die "backup retention keeps nothing — set at least one of backup.keep_daily/weekly/monthly"
  restic forget --tag "${env},complete" --group-by host "${keep[@]}" >&2 \
    && restic forget --tag "${env},incomplete" --group-by host --keep-last 2 --prune >&2 \
    || warn "could not remove old backups (the new one is saved)"

  if (( failed )); then
    die "backup saved, but incomplete — see the warnings above"
  fi

  date -u +%Y-%m-%dT%H:%M:%SZ > "$last_success_file"
  local ping_url
  ping_url="$(yq_get "$config_file" '.backup.ping_url')"
  if [[ -n "$ping_url" ]]; then
    curl -fsS -m 10 -o /dev/null "$ping_url" || warn "could not reach the ping URL"
  fi
  log "backup complete"
}

# --- list / status ---------------------------------------------------------

do_list() {
  require_ready
  restic snapshots --tag "$env"
}

do_status() {
  require_ready
  if [[ ! -f "$last_success_file" ]]; then
    die "no successful backup recorded on this host"
  fi
  local last now then_s age_hours
  last="$(cat "$last_success_file")"
  now="$(date -u +%s)"
  # GNU date first, BSD date (macOS) as the fallback.
  then_s="$(date -u -d "$last" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$last" +%s)"
  age_hours=$(( (now - then_s) / 3600 ))
  printf 'last successful backup: %s (%s hour(s) ago)\n' "$last" "$age_hours"
  printf 'repository: %s\n' "$repository"
  (( age_hours <= MAX_AGE_HOURS )) || die "last successful backup is older than ${MAX_AGE_HOURS} hours"
}

# --- restore ---------------------------------------------------------------

# Copies a whole snapshot into a directory. Changes nothing that is running.
do_restore() {
  [[ $# -eq 2 ]] || die "usage: quarantine backup restore <snapshot|latest> <empty-directory>"
  require_ready
  local snapshot="$1" target="$2"
  mkdir -p "$target"
  [[ -z "$(ls -A "$target")" ]] || die "target directory is not empty: ${target}"
  target="$(cd "$target" && pwd)"
  local -a pick=()
  mapfile -t pick < <(latest_filter "$snapshot")
  restic --mount "${target}:/target" restore "${pick[@]}" "$snapshot" --target /target >&2
  log "restored into ${target} (volumes/, staging/postgres/dumpall.sql, staging/sqlite/, host/)"
}

# Puts one volume back the way it was in a snapshot.
do_restore_volume() {
  [[ $# -eq 2 ]] || die "usage: quarantine backup restore-volume <snapshot|latest> <volume>"
  require_ready
  local snapshot="$1" vol="$2" users
  local -a pick=()
  mapfile -t pick < <(latest_filter "$snapshot")

  # "snapshot:/path" fails when the path is missing. A plain "ls snapshot
  # /path" does not: it just lists nothing.
  restic ls "${pick[@]}" "${snapshot}:/volumes/${vol}" >/dev/null 2>&1 \
    || die "volume '${vol}' is not in snapshot '${snapshot}' (see 'quarantine backup list')"

  users="$(docker ps --filter "volume=${vol}" --format '{{.Names}}' | tr '\n' ' ')"
  [[ -z "${users// }" ]] || die "stop the container(s) using this volume first: ${users}"

  warn "this replaces everything in volume '${vol}' with its content from snapshot '${snapshot}'"
  if [[ "${QUARANTINE_ASSUME_YES:-}" != "true" ]]; then
    confirm_typed "Type the volume name to continue" "$vol" || die "confirmation failed — aborted"
  fi

  docker volume create "$vol" >/dev/null

  # Step 1 restores the files. Step 2 puts the clean SQLite copies over the
  # raw ones and removes leftover journal files, which belong to the raw
  # copies and would corrupt the clean ones.
  local has_sqlite=0
  restic ls "${pick[@]}" "${snapshot}:/staging/sqlite/${vol}" >/dev/null 2>&1 && has_sqlite=1

  local script
  script="set -eu
restic restore ${pick[*]} \"${snapshot}:/volumes/${vol}\" --target /target --delete
owner=\$(restic dump ${pick[*]} \"${snapshot}\" /staging/volume-owners 2>/dev/null | awk -v v=\"${vol}\" '\$1 == v { print \$2 \":\" \$3 \" \" \$4 }')
if [ -n \"\$owner\" ]; then
  chown \"\${owner% *}\" /target
  chmod \"\${owner#* }\" /target
fi
if [ \"${has_sqlite}\" = 1 ]; then
  mkdir /overlay
  restic restore ${pick[*]} \"${snapshot}:/staging/sqlite/${vol}\" --target /overlay
  cd /overlay
  find . -type f | while IFS= read -r f; do
    cp -p \"\$f\" \"/target/\$f\"
    rm -f \"/target/\$f-wal\" \"/target/\$f-shm\" \"/target/\$f-journal\"
  done
fi"

  local -a docker_args=(run --rm --network host --hostname "quarantine-${env}"
    -e RESTIC_PASSWORD -e RESTIC_REPOSITORY
    -v "quarantine-restic-cache:/root/.cache/restic"
    -v "${vol}:/target" --entrypoint /bin/sh)
  local repo_in_container="$repository"
  [[ -d "$ssh_dir" ]] && docker_args+=(-v "${ssh_dir}:/root/.ssh")
  if [[ "$repository" == /* ]]; then
    docker_args+=(-v "${repository}:/repo")
    repo_in_container="/repo"
  fi
  RESTIC_PASSWORD="$password" RESTIC_REPOSITORY="$repo_in_container" \
    docker "${docker_args[@]}" "$RESTIC_IMAGE" -c "$script" >&2

  log "volume '${vol}' restored — start its container(s) again"
}

case "$mode" in
  init) do_init "$@" ;;
  run) do_run "$@" ;;
  list) do_list "$@" ;;
  status) do_status "$@" ;;
  restore) do_restore "$@" ;;
  restore-volume) do_restore_volume "$@" ;;
  *) die "unknown mode: ${mode}" ;;
esac
