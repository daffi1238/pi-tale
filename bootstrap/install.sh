#!/usr/bin/env bash
# pi-tale — main installer.
#
# Idempotent: safe to run multiple times. Performs the minimum amount of
# host-side preparation needed before `docker compose up`.
#
# Steps:
#   1. Confirm we are on a Raspberry Pi (or warn loudly otherwise).
#   2. Ensure Docker and the compose plugin are installed.
#   3. Ensure the SSD is mounted at /mnt/datos (or warn).
#   4. Create the ./data/<service> directories with the right ownership.
#   5. Bootstrap compose/.env from compose/.env.example.
#   6. Print the next steps.
#
# Usage: sudo bootstrap/install.sh
set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Pretty logging
# ----------------------------------------------------------------------------

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_BLUE=$'\033[34m'
else
  C_RESET=""; C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""
fi

info()    { printf '%s[i]%s %s\n' "${C_BLUE}"   "${C_RESET}" "$*"; }
ok()      { printf '%s[ok]%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
warn()    { printf '%s[!]%s  %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
err()     { printf '%s[x]%s  %s\n' "${C_RED}"   "${C_RESET}" "$*" >&2; }
section() { printf '\n%s== %s ==%s\n' "${C_BOLD}" "$*" "${C_RESET}"; }

trap 'err "install.sh failed on line $LINENO. See the message above for the cause."' ERR

# ----------------------------------------------------------------------------
# Paths
# ----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV_EXAMPLE="${REPO_ROOT}/compose/.env.example"
ENV_FILE="${REPO_ROOT}/compose/.env"
DATA_ROOT="${REPO_ROOT}/data"
SSD_MOUNT="/mnt/datos"

REAL_USER="${SUDO_USER:-${USER}}"
REAL_GROUP="$(id -gn "${REAL_USER}")"

# ----------------------------------------------------------------------------
# Pre-flight
# ----------------------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
  err "Run this script with sudo (it needs to create dirs, install packages, write to /etc)."
  exit 1
fi

section "Detecting hardware"

if [[ -r /sys/firmware/devicetree/base/model ]]; then
  MODEL="$(tr -d '\0' </sys/firmware/devicetree/base/model)"
  if [[ "${MODEL}" == *"Raspberry Pi"* ]]; then
    ok "Detected: ${MODEL}"
  else
    warn "Hardware does not look like a Raspberry Pi (${MODEL})."
    warn "pi-tale will probably still work but is only tested on Pi 4 / Pi 5."
  fi
else
  warn "Cannot read /sys/firmware/devicetree/base/model — non-Pi host?"
fi

ARCH="$(uname -m)"
case "${ARCH}" in
  aarch64|arm64) ok "Architecture: ${ARCH}" ;;
  *) warn "Architecture is ${ARCH}; pi-tale targets arm64. Images may not start." ;;
esac

# ----------------------------------------------------------------------------
# Docker + compose plugin
# ----------------------------------------------------------------------------

section "Checking Docker"

if command -v docker >/dev/null 2>&1; then
  ok "Docker present: $(docker --version)"
else
  warn "Docker is not installed."
  if [[ -x "${SCRIPT_DIR}/docker-setup.sh" ]]; then
    info "Running bootstrap/docker-setup.sh to install Docker..."
    "${SCRIPT_DIR}/docker-setup.sh"
  else
    err  "bootstrap/docker-setup.sh is missing or not executable."
    err  "Install Docker manually (https://docs.docker.com/engine/install/debian/) and re-run this script."
    exit 1
  fi
fi

if docker compose version >/dev/null 2>&1; then
  ok "Docker Compose plugin present: $(docker compose version --short 2>/dev/null || echo unknown)"
else
  err "Docker Compose plugin missing. Install docker-compose-plugin and re-run."
  exit 1
fi

if ! getent group docker | grep -q "\b${REAL_USER}\b"; then
  warn "User '${REAL_USER}' is not in the docker group; running 'usermod -aG docker ${REAL_USER}'."
  usermod -aG docker "${REAL_USER}"
  warn "You will need to log out and back in for the group change to apply."
fi

# ----------------------------------------------------------------------------
# SSD check
# ----------------------------------------------------------------------------

section "Checking persistent storage"

if mountpoint -q "${SSD_MOUNT}"; then
  ok "${SSD_MOUNT} is a mountpoint."
  AVAIL_GB=$(df -BG "${SSD_MOUNT}" | awk 'NR==2 {gsub("G","",$4); print $4}')
  ok "Available space on ${SSD_MOUNT}: ${AVAIL_GB} GB"
  if (( AVAIL_GB < 20 )); then
    warn "Less than 20 GB free on ${SSD_MOUNT}; consider a larger SSD before going to production."
  fi
else
  warn "${SSD_MOUNT} is not mounted."
  warn "pi-tale will store data under ${DATA_ROOT}, which lives on the boot device."
  warn "On a Raspberry Pi this almost certainly means the microSD card — Prometheus,"
  warn "Loki and the rest will chew through it quickly."
  warn ""
  warn "Run    sudo bootstrap/ssd-setup.sh    once you have plugged in an SSD."
fi

# ----------------------------------------------------------------------------
# Data directories
# ----------------------------------------------------------------------------

section "Preparing data directories"

# (path, uid, gid)  — uids match the user each container drops to.
# uptime-kuma lives in extras.yml but we prepare its directory up-front;
# the empty dir costs nothing and saves a re-run when the operator
# enables extras later.
declare -a DATA_DIRS=(
  "prometheus|65534|65534"
  "alertmanager|65534|65534"
  "grafana|472|472"
  "loki|10001|10001"
  "promtail|0|0"
  "uptime-kuma|0|0"
)

mkdir -p "${DATA_ROOT}"
chown "${REAL_USER}:${REAL_GROUP}" "${DATA_ROOT}" || true

for entry in "${DATA_DIRS[@]}"; do
  IFS='|' read -r name uid gid <<<"${entry}"
  d="${DATA_ROOT}/${name}"
  if [[ ! -d "${d}" ]]; then
    mkdir -p "${d}"
    info "Created ${d}"
  fi
  chown -R "${uid}:${gid}" "${d}"
  chmod 0750 "${d}"
done

ok "Data directories ready under ${DATA_ROOT}"

# ----------------------------------------------------------------------------
# .env bootstrap
# ----------------------------------------------------------------------------

section "Configuring environment"

if [[ ! -f "${ENV_FILE}" ]]; then
  if [[ ! -f "${ENV_EXAMPLE}" ]]; then
    err "${ENV_EXAMPLE} is missing — repository is incomplete."
    exit 1
  fi
  cp "${ENV_EXAMPLE}" "${ENV_FILE}"
  chown "${REAL_USER}:${REAL_GROUP}" "${ENV_FILE}"
  chmod 0600 "${ENV_FILE}"
  ok "Created compose/.env from .env.example (mode 0600)."
  warn "Edit compose/.env before bringing the stack up. At minimum, set GRAFANA_ADMIN_PASSWORD."
else
  ok "compose/.env already exists; leaving it alone."
fi

# ----------------------------------------------------------------------------
# Next steps
# ----------------------------------------------------------------------------

section "Done"

cat <<EOF

  ${C_BOLD}Next steps:${C_RESET}

    1. Edit ${C_BOLD}compose/.env${C_RESET} and set, at minimum, GRAFANA_ADMIN_PASSWORD.
    2. (Optional) Drop new probe targets in prometheus/targets/.
    3. Bring the stack up:

         docker compose -f compose/core.yml --env-file compose/.env up -d

    4. Open Grafana at ${C_BOLD}http://$(hostname -I | awk '{print $1}'):${GRAFANA_PORT:-3000}${C_RESET}
       (user: admin, password: whatever you set in .env).

  If something fails, check:
    - docker compose -f compose/core.yml --env-file compose/.env logs --tail=100
    - docs/troubleshooting.md
EOF
