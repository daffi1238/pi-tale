#!/usr/bin/env bash
# pi-tale — restore persistent data from a backup archive.
#
# Companion to scripts/backup.sh. Given a tarball produced by that
# script (top-level `data/` directory inside), this:
#
#   1. Validates the archive.
#   2. Stops every running pi-tale compose project.
#   3. Moves the current DATA_ROOT aside as data.bak-<timestamp> (kept,
#      not deleted, so an operator mistake is reversible).
#   4. Extracts the archive in place, preserving uids/permissions.
#   5. Restarts only the stacks that were running before the restore.
#
# Usage:
#   scripts/restore.sh path/to/pi-tale-backup-YYYYMMDD-HHMMSSZ.tar.gz
#   scripts/restore.sh --yes path/to/archive.tar.gz   # skip the prompt
#
# Env overrides:
#   DATA_ROOT  destination directory (default: <repo>/data)
#
# Exit codes:
#   0  ok
#   1  generic failure
#   2  pre-flight failure (missing archive, wrong shape, ...)
#   3  user aborted

set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Logging (matches bootstrap/install.sh)
# ----------------------------------------------------------------------------

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_BLUE=$'\033[34m'
else
  C_RESET=""; C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""
fi

info()    { printf '%s[i]%s %s\n'  "${C_BLUE}"   "${C_RESET}" "$*"; }
ok()      { printf '%s[ok]%s %s\n' "${C_GREEN}"  "${C_RESET}" "$*"; }
warn()    { printf '%s[!]%s  %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
err()     { printf '%s[x]%s  %s\n' "${C_RED}"    "${C_RESET}" "$*" >&2; }
section() { printf '\n%s== %s ==%s\n' "${C_BOLD}" "$*" "${C_RESET}"; }

trap 'err "restore.sh failed on line $LINENO."' ERR

# ----------------------------------------------------------------------------
# Paths
# ----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DATA_ROOT="${DATA_ROOT:-${REPO_ROOT}/data}"

COMPOSE_PROJECTS=(pi-tale-core pi-tale-probes pi-tale-extras)
declare -a PROJECTS_TO_RESTART=()

ASSUME_YES=0
ARCHIVE=""

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while (($#)); do
  case "$1" in
    -y|--yes)    ASSUME_YES=1 ;;
    -h|--help)   usage 0 ;;
    -*)          err "Unknown flag: $1"; usage 2 ;;
    *)           if [[ -z "${ARCHIVE}" ]]; then ARCHIVE="$1"; else err "Unexpected arg: $1"; usage 2; fi ;;
  esac
  shift
done

# ----------------------------------------------------------------------------
# Pre-flight
# ----------------------------------------------------------------------------

section "Pre-flight"

if [[ -z "${ARCHIVE}" ]]; then
  err "No archive given."; usage 2
fi
if [[ ! -f "${ARCHIVE}" ]]; then
  err "Archive does not exist: ${ARCHIVE}"; exit 2
fi
ARCHIVE="$(cd "$(dirname "${ARCHIVE}")" && pwd)/$(basename "${ARCHIVE}")"

for tool in tar gzip; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    err "Required tool '${tool}' is not installed."; exit 2
  fi
done

# Quick shape check: the archive must contain a top-level `data/` dir.
info "Inspecting ${ARCHIVE}"
if ! tar -tzf "${ARCHIVE}" >/dev/null 2>&1; then
  err "Archive is not a readable gzip tarball."; exit 2
fi
if ! tar -tzf "${ARCHIVE}" | grep -qE '^data/'; then
  err "Archive does not contain a top-level data/ directory; refusing to restore."
  err "(Expected layout produced by scripts/backup.sh.)"
  exit 2
fi

ARCHIVE_SIZE="$(du -h "${ARCHIVE}" | awk '{print $1}')"
ARCHIVE_ENTRIES="$(tar -tzf "${ARCHIVE}" | wc -l)"
ok "Archive ok: ${ARCHIVE_SIZE}, ${ARCHIVE_ENTRIES} entries."

# Need to be root because the archive carries uids 65534/472/10001/etc.
if [[ "${EUID}" -ne 0 ]]; then
  err "Run with sudo so file ownership (uid 65534/472/10001/...) can be restored."
  exit 2
fi

# ----------------------------------------------------------------------------
# Confirmation
# ----------------------------------------------------------------------------

cat <<EOF

  About to RESTORE pi-tale data:
    archive:     ${ARCHIVE}
    destination: ${DATA_ROOT}

  This will:
    - stop every running pi-tale compose project
    - move the current ${DATA_ROOT} aside as ${DATA_ROOT}.bak-<timestamp>
    - extract the archive into ${DATA_ROOT}
    - restart the stacks that were running before

EOF

if (( ASSUME_YES == 0 )); then
  read -r -p "Continue? [y/N] " reply
  case "${reply}" in
    y|Y|yes|YES) ;;
    *) warn "Aborted by user."; exit 3 ;;
  esac
fi

# ----------------------------------------------------------------------------
# Stop running stacks
# ----------------------------------------------------------------------------

compose_running() {
  local project="$1"
  if ! command -v docker >/dev/null 2>&1; then return 1; fi
  docker ps --filter "label=com.docker.compose.project=${project}" --format '{{.Names}}' | grep -q .
}

compose_for() {
  case "$1" in
    pi-tale-core)    echo "${REPO_ROOT}/compose/core.yml"   ;;
    pi-tale-probes)  echo "${REPO_ROOT}/compose/probes.yml" ;;
    pi-tale-extras)  echo "${REPO_ROOT}/compose/extras.yml" ;;
    *) return 1 ;;
  esac
}

section "Stopping running stacks"
for project in "${COMPOSE_PROJECTS[@]}"; do
  if compose_running "${project}"; then
    info "Stopping ${project}..."
    docker compose -f "$(compose_for "${project}")" --env-file "${REPO_ROOT}/compose/.env" stop
    PROJECTS_TO_RESTART+=("${project}")
  fi
done
(( ${#PROJECTS_TO_RESTART[@]} == 0 )) && info "Nothing was running."

restart_stacks() {
  if (( ${#PROJECTS_TO_RESTART[@]} == 0 )); then return 0; fi
  section "Restarting stacks"
  for project in "${PROJECTS_TO_RESTART[@]}"; do
    info "Starting ${project}..."
    docker compose -f "$(compose_for "${project}")" --env-file "${REPO_ROOT}/compose/.env" start \
      || warn "Could not restart ${project}; do it manually."
  done
}
trap 'restart_stacks; err "restore.sh failed on line $LINENO."' ERR

# ----------------------------------------------------------------------------
# Move current data/ aside, extract archive
# ----------------------------------------------------------------------------

section "Restoring data"

TIMESTAMP="$(date -u +%Y%m%d-%H%M%SZ)"
DATA_PARENT="$(dirname "${DATA_ROOT}")"

if [[ -e "${DATA_ROOT}" ]]; then
  BACKUP_OF_CURRENT="${DATA_ROOT}.bak-${TIMESTAMP}"
  info "Moving current data aside: ${DATA_ROOT} -> ${BACKUP_OF_CURRENT}"
  mv "${DATA_ROOT}" "${BACKUP_OF_CURRENT}"
fi

info "Extracting archive into ${DATA_PARENT}"
tar \
  --numeric-owner \
  -xzf "${ARCHIVE}" \
  -C "${DATA_PARENT}" \
  data

if [[ ! -d "${DATA_ROOT}" ]]; then
  err "Extraction did not produce ${DATA_ROOT}. Aborting before stacks restart."
  exit 1
fi
ok "Data restored at ${DATA_ROOT}."

restart_stacks
trap - ERR

section "Done"
if [[ -n "${BACKUP_OF_CURRENT:-}" ]]; then
  ok  "Previous data preserved at ${BACKUP_OF_CURRENT} — delete it once you're happy."
fi
ok "Restore complete."
