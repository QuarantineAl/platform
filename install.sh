#!/usr/bin/env bash
# install.sh — curl-able bootstrapper for quarantine.
#
# Usage: curl -fsSL <raw-url-to-this-file> | sudo bash
#
# Installs every system dependency quarantine needs (Docker + compose
# plugin, git, curl, age, sops, yq, flock), clones this repo to
# /opt/quarantine/repo (or updates it if already present), and symlinks
# bin/quarantine onto PATH at /usr/local/bin/quarantine.
#
# Supported platforms: Debian/Ubuntu (apt-get) on x86_64 or arm64 only —
# this project's verified deployment target is Ubuntu 24.04. Anything else:
# see docs/client-install.md for a manual walkthrough.
#
# Must run as root (everything it does — installing packages, writing to
# /opt and /usr/local/bin — needs it): curl ... | sudo bash.

set -euo pipefail

QUARANTINE_REPO_URL="${QUARANTINE_REPO_URL:-https://github.com/YOUR_ORG/quarantine.git}"
QUARANTINE_INSTALL_DIR="${QUARANTINE_INSTALL_DIR:-/opt/quarantine/repo}"
QUARANTINE_BIN_LINK="${QUARANTINE_BIN_LINK:-/usr/local/bin/quarantine}"

# PIN CHECKPOINT: sops v3.13.3, yq (mikefarah) v4.53.3 (verified 2026-07-26).
# Installed by downloading the exact pinned Linux binary and verifying its
# SHA-256 against the hash recorded here (copied from each project's own
# published release checksums, cross-checked against a fresh download at
# pin time) — never installed via `apt-get install sops`/`apt-get install
# yq`, which either doesn't exist (sops) or resolves to an unrelated,
# incompatible tool (Debian/Ubuntu's `yq` package is kislyuk/yq, a Python
# wrapper with different expression syntax than the mikefarah/yq this
# entire codebase is written against — see lib/common.sh).
SOPS_VERSION="3.13.3"
YQ_VERSION="4.53.3"
SOPS_SHA256_AMD64="e5bec3346a873ae91d871550f3e698c1aad962aff462a080e40f25fde17fef6b"
SOPS_SHA256_ARM64="53b0abacd38ef1b12a66d6c100956691b9cefce018d91f81e73ddf7438b94d77"
YQ_SHA256_AMD64="fa52a4e758c63d38299163fbdd1edfb4c4963247918bf9c1c5d31d84789eded4"
YQ_SHA256_ARM64="578648e463a11c1b6db6010cbf41eafed6bee79466fcffa1bb446672cf7945ea"

log() { printf '\033[36m[install]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[install] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "must run as root — curl ... | sudo bash"
command -v apt-get >/dev/null 2>&1 \
  || die "this installer supports Debian/Ubuntu (apt-get) only — see docs/client-install.md for other distros"

case "$(uname -m)" in
  x86_64) ARCH=amd64; SOPS_SHA256="$SOPS_SHA256_AMD64"; YQ_SHA256="$YQ_SHA256_AMD64" ;;
  aarch64|arm64) ARCH=arm64; SOPS_SHA256="$SOPS_SHA256_ARM64"; YQ_SHA256="$YQ_SHA256_ARM64" ;;
  *) die "unsupported architecture: $(uname -m) (only x86_64/arm64)" ;;
esac

# fetch_verified <url> <expected_sha256> <dest_path>
# Downloads to a tempfile first, verifies its checksum, and only then moves
# it into place — a failed/tampered download never reaches <dest_path>.
fetch_verified() {
  local url="$1" expected="$2" dest="$3" tmp actual
  tmp="$(mktemp)"
  curl -fsSL -o "$tmp" "$url" || { rm -f "$tmp"; die "failed to download ${url}"; }
  actual="$(sha256sum "$tmp" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    rm -f "$tmp"
    die "checksum mismatch for ${url}: expected ${expected}, got ${actual} — refusing to install"
  fi
  chmod +x "$tmp"
  mv "$tmp" "$dest"
}

log "updating apt package index"
apt-get update -qq

log "installing base packages: git curl age ca-certificates"
apt-get install -y -qq git curl age ca-certificates >/dev/null

if ! command -v docker >/dev/null 2>&1; then
  log "installing Docker (official convenience script: get.docker.com)"
  curl -fsSL https://get.docker.com | sh
fi
docker compose version >/dev/null 2>&1 \
  || die "docker compose (v2 plugin) not found after Docker install — see docs/client-install.md"

log "installing sops v${SOPS_VERSION}"
fetch_verified \
  "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.${ARCH}" \
  "$SOPS_SHA256" /usr/local/bin/sops

log "installing yq v${YQ_VERSION} (mikefarah/yq)"
fetch_verified \
  "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${ARCH}" \
  "$YQ_SHA256" /usr/local/bin/yq

command -v flock >/dev/null 2>&1 \
  || die "flock not found (part of util-linux — expected preinstalled on any standard Debian/Ubuntu host)"

if [[ -d "${QUARANTINE_INSTALL_DIR}/.git" ]]; then
  log "updating existing checkout at ${QUARANTINE_INSTALL_DIR}"
  git -C "$QUARANTINE_INSTALL_DIR" pull --ff-only
else
  log "cloning ${QUARANTINE_REPO_URL} to ${QUARANTINE_INSTALL_DIR}"
  mkdir -p "$(dirname "$QUARANTINE_INSTALL_DIR")"
  git clone --depth 1 "$QUARANTINE_REPO_URL" "$QUARANTINE_INSTALL_DIR"
fi

chmod +x "${QUARANTINE_INSTALL_DIR}/bin/quarantine"
ln -sf "${QUARANTINE_INSTALL_DIR}/bin/quarantine" "$QUARANTINE_BIN_LINK"

log "installed. Next: quarantine init"
