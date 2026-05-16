#!/usr/bin/env bash
# pi-tale — backup persistent data.
#
# Creates a date-stamped tarball of the bind-mounted `data/<service>`
# directories under the repo root (or DATA_ROOT, if you keep it
# elsewhere). To get a self-consistent snapshot of Prometheus, Loki,
# Grafana and Alertmanager we briefly stop the running pi-tale compose
# projects, tar the data and bring them back up.
#
# Usage:
#   scripts/backup.sh                 # stop stacks, tar data/, restart
#   scripts/backup.sh --live          # tar without stopping (best-effort)
#   scripts/backup.sh --include-env   # also include compose/.env (secrets!)
#   scripts/backup.sh --dest /mnt/usb/pi-tale-backups
#
# Env overrides:
#   BACKUP_DIR   destination directory (default: <repo>/backup)
#   BACKUP_KEEP  how many archives to retain (default: 7)
#   DATA_ROOT    source directory (default: <repo>/data)
#
# Exit codes:
#   0  ok
#   1  generic failure
#   2  pre-flight failure (paths, tools)

set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Pretty logging (matches bootstrap/install.sh conventions)
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

trap 'err "backup.sh failed on line $LINENO."' ERR

# ----------------------------------------------------------------------------
# Paths
# ----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DATA_ROOT="${DATA_ROOT:-${REPO_ROOT}/data}"
BACKUP_DIR="${BACKUP_DIR:-${REPO_ROOT}/backup}"
BACKUP_KEEP="${BACKUP_KEEP:-7}"

# pi-tale ships three compose projects. We probe each by name; only the
# ones that are actually running get stopped and restarted.
COMPOSE_PROJECTS=(pi-tale-core pi-tale-probes pi-tale-extras)
declare -a PROJECTS_TO_RESTART=()

# Flags
LIVE=0
INCLUDE_ENV=0

# ----------------------------------------------------------------------------
# Arg parsing
# ----------------------------------------------------------------------------

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while (($#)); do
  case "$1" in
    --live)         LIVE=1 ;;
    --include-env)  INCLUDE_ENV=1 ;;
    --dest)         shift; BACKUP_DIR="${1:?--dest requires a path}" ;;
    -h|--help)      usage 0 ;;
    *)              err "Unknown argument: $1"; usage 2 ;;
  esac
  shift
done

# ----------------------------------------------------------------------------
# Pre-flight
# ----------------------------------------------------------------------------

section "Pre-flight"

for tool in tar gzip find; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    err "Required tool '${tool}' is not installed."; exit 2
  fi
done

if [[ ! -d "${DATA_ROOT}" ]]; then
  err "DATA_ROOT (${DATA_ROOT}) does not exist. Nothing to back up."; exit 2
fi

if ! find "${DATA_ROOT}" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
  err "DATA_ROOT (${DATA_ROOT}) is empty. Nothing to back up."; exit 2
fi

# tar needs to read files owned by 65534 (Prometheus), 472 (Grafana),
# 10001 (Loki). Running as a non-root user without the relevant group
# membership will silently produce a half-empty archive. Refuse early.
if [[ "${EUID}" -ne 0 ]]; then
  if find "${DATA_ROOT}" -maxdepth 2 ! -readable -print -quit 2>/dev/null | grep -q .; then
    err "Some files under ${DATA_ROOT} are not readable as $(id -un)."
    err "Re-run with sudo:  sudo BACKUP_DIR='${BACKUP_DIR}' scripts/backup.sh"
    exit 2
  fi
fi

mkdir -p "${BACKUP_DIR}"
ok "Source:      ${DATA_ROOT}"
ok "Destination: ${BACKUP_DIR}"
ok "Retention:   ${BACKUP_KEEP} archives"

# ----------------------------------------------------------------------------
# Stop running stacks (unless --live)
# ----------------------------------------------------------------------------

compose_running() {
  # Echoes the project name if at least one of its services is up.
  local project="$1"
  if ! command -v docker >/dev/null 2>&1; then return 1; fi
  docker ps --filter "label=com.docker.compose.project=${project}" --format '{{.Names}}' \
    | grep -q .
}

restart_project() {
  local project="$1"
  case "${project}" in
    pi-tale-core)    compose_file="${REPO_ROOT}/compose/core.yml"   ;;
    pi-tale-probes)  compose_file="${REPO_ROOT}/compose/probes.yml" ;;
    pi-tale-extras)  compose_file="${REPO_ROOT}/compose/extras.yml" ;;
    *) err "Unknown compose project: ${project}"; return 1 ;;
  esac
  docker compose -f "${compose_file}" --env-file "${REPO_ROOT}/compose/.env" "$@"
}

if (( LIVE == 0 )); then
  section "Stopping running stacks"
  for project in "${COMPOSE_PROJECTS[@]}"; do
    if compose_running "${project}"; then
      info "Stopping ${project}..."
      restart_project "${project}" stop
      PROJECTS_TO_RESTART+=("${project}")
    fi
  done
  if (( ${#PROJECTS_TO_RESTART[@]} == 0 )); then
    info "No pi-tale compose projects are currently running."
  fi
else
  warn "Running in --live mode. Prometheus/Loki/Grafana files may be inconsistent."
fi

# Ensure we always try to restart whatever we stopped, even on failure.
restart_stacks() {
  if (( ${#PROJECTS_TO_RESTART[@]} == 0 )); then return 0; fi
  section "Restarting stacks"
  for project in "${PROJECTS_TO_RESTART[@]}"; do
    info "Starting ${project}..."
    restart_project "${project}" start || warn "Could not restart ${project}; do it manually."
  done
}
trap 'restart_stacks; err "backup.sh failed on line $LINENO."' ERR

# ----------------------------------------------------------------------------
# Build the archive
# ----------------------------------------------------------------------------

section "Creating archive"

TIMESTAMP="$(date -u +%Y%m%d-%H%M%SZ)"
ARCHIVE="${BACKUP_DIR}/pi-tale-backup-${TIMESTAMP}.tar.gz"
ARCHIVE_TMP="${ARCHIVE}.partial"

# We tar relative to the parent of DATA_ROOT so the archive contains a
# top-level `data/` directory regardless of where the source lived.
DATA_PARENT="$(dirname "${DATA_ROOT}")"
DATA_BASE="$(basename "${DATA_ROOT}")"

# Collect the paths we want inside the archive, expressed relative to
# DATA_PARENT (so tar's `-C` works cleanly).
declare -a TAR_ENTRIES=("${DATA_BASE}")

if (( INCLUDE_ENV == 1 )); then
  if [[ -f "${REPO_ROOT}/compose/.env" ]]; then
    # Copy .env to a staging dir so it ends up alongside data/ at the
    # archive root, rather than buried under an absolute path.
    STAGE_DIR="$(mktemp -d)"
    trap 'rm -rf "${STAGE_DIR}"; restart_stacks' EXIT
    cp -p "${REPO_ROOT}/compose/.env" "${STAGE_DIR}/.env"
    chmod 0600 "${STAGE_DIR}/.env"
    warn "Including compose/.env in the archive — contains secrets, store it carefully."
  else
    warn "--include-env requested but compose/.env not found; skipping."
    INCLUDE_ENV=0
  fi
fi

info "Writing ${ARCHIVE}"

# --numeric-owner: keep the uids stored in the archive so restore on a
# different host still maps to the right service users.
# --warning=no-file-changed: Loki/Prometheus may rotate small files even
# when stopped (e.g. WAL truncation on shutdown); we accept those.
tar \
  --numeric-owner \
  --warning=no-file-changed \
  --warning=no-file-removed \
  -C "${DATA_PARENT}" \
  -czf "${ARCHIVE_TMP}" \
  "${TAR_ENTRIES[@]}"

if (( INCLUDE_ENV == 1 )); then
  tar \
    --numeric-owner \
    -C "${STAGE_DIR}" \
    -rzf "${ARCHIVE_TMP}" \
    .env 2>/dev/null || {
      # gzip-compressed tarballs cannot be appended to with -r. Fall
      # back to a second archive next to the main one rather than
      # silently dropping the file.
      cp -p "${STAGE_DIR}/.env" "${BACKUP_DIR}/pi-tale-env-${TIMESTAMP}.env"
      chmod 0600 "${BACKUP_DIR}/pi-tale-env-${TIMESTAMP}.env"
      warn "compose/.env was saved separately: pi-tale-env-${TIMESTAMP}.env"
    }
fi

mv "${ARCHIVE_TMP}" "${ARCHIVE}"
chmod 0640 "${ARCHIVE}"

SIZE_HUMAN="$(du -h "${ARCHIVE}" | awk '{print $1}')"
ok "Archive ready: ${ARCHIVE} (${SIZE_HUMAN})"

# ----------------------------------------------------------------------------
# Rotate
# ----------------------------------------------------------------------------

section "Rotating old archives"

mapfile -t ARCHIVES < <(
  find "${BACKUP_DIR}" -maxdepth 1 -type f -name 'pi-tale-backup-*.tar.gz' -printf '%T@\t%p\n' \
    | sort -rn \
    | cut -f2-
)

if (( ${#ARCHIVES[@]} > BACKUP_KEEP )); then
  for old in "${ARCHIVES[@]:BACKUP_KEEP}"; do
    info "Removing ${old}"
    rm -f "${old}"
    # Drop the matching env sidecar, if any.
    ts="${old##*pi-tale-backup-}"; ts="${ts%.tar.gz}"
    rm -f "${BACKUP_DIR}/pi-tale-env-${ts}.env"
  done
else
  ok "Nothing to rotate (${#ARCHIVES[@]} archive(s) <= keep=${BACKUP_KEEP})."
fi

# ----------------------------------------------------------------------------
# Restart and report
# ----------------------------------------------------------------------------

restart_stacks
trap - ERR EXIT

section "Done"
ok "Backup complete: ${ARCHIVE}"
