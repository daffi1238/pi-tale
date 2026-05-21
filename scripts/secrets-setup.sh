#!/usr/bin/env bash
# pi-tale — install plain-secret-file copies of GRAFANA_ADMIN_PASSWORD
# and (optionally) SMTP_PASSWORD outside of any committed YAML.
#
# Both consumers — Grafana via GF_SECURITY_ADMIN_PASSWORD__FILE and
# Alertmanager via smtp_auth_password_file — read the file content as
# the secret at startup. That means:
#
#   - The password lives in compose/.env (gitignored) AND in
#     data/<service>/secrets/<name> (also gitignored). Two copies, never
#     in a committed file.
#   - Rotating the password is: edit compose/.env, re-run this script,
#     restart the affected container so it re-reads the file. For
#     Grafana that is `docker compose -f compose/core.yml restart grafana`.
#     Alertmanager picks SMTP changes up on `/-/reload`.
#
# Why bother (this is a homelab, who cares):
#   - `docker inspect` and `docker compose config` no longer leak the
#     password into anyone's shell history / scrollback / pastebin.
#   - The compose YAML in git or a backup tarball never carries the
#     secret (`*_FILE` only carries a path).
#   - Alertmanager's rendered config (data/alertmanager/runtime/
#     alertmanager.yml) never contains the SMTP password either; only
#     the path to the secret file.
#
# Usage:
#   sudo scripts/secrets-setup.sh
#
# Exit codes:
#   0 ok
#   1 generic failure
#   2 pre-flight failure (no .env, missing required value, wrong perms)

set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Logging (matches bootstrap/install.sh and telegram-setup.sh)
# ----------------------------------------------------------------------------

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_BLUE=$'\033[34m'
else
  C_RESET=""
  C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""
fi

info()  { printf '%s[i]%s %s\n'  "${C_BLUE}"   "${C_RESET}" "$*"; }
ok()    { printf '%s[ok]%s %s\n' "${C_GREEN}"  "${C_RESET}" "$*"; }
warn()  { printf '%s[!]%s  %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
err()   { printf '%s[x]%s  %s\n' "${C_RED}"    "${C_RESET}" "$*" >&2; }

trap 'err "secrets-setup.sh failed on line $LINENO."' ERR

# ----------------------------------------------------------------------------
# Pre-flight
# ----------------------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
  err "Run with sudo. The target directories are owned by service uids (472, 65534)."
  err "  sudo scripts/secrets-setup.sh"
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV_FILE="${REPO_ROOT}/compose/.env"

GRAFANA_SECRETS_DIR="${REPO_ROOT}/data/grafana/secrets"
GRAFANA_PASSWORD_FILE="${GRAFANA_SECRETS_DIR}/admin_password"

AM_SECRETS_DIR="${REPO_ROOT}/data/alertmanager/secrets"
SMTP_PASSWORD_FILE="${AM_SECRETS_DIR}/smtp_password"

if [[ ! -f "${ENV_FILE}" ]]; then
  err "${ENV_FILE} not found. Run bootstrap/install.sh first."
  exit 2
fi

for d in "${GRAFANA_SECRETS_DIR}" "${AM_SECRETS_DIR}"; do
  if [[ ! -d "${d}" ]]; then
    err "${d} is missing. Re-run bootstrap/install.sh — it creates these with the right ownership."
    exit 2
  fi
done

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

# Same shape as scripts/telegram-setup.sh. Last non-commented value wins;
# trims whitespace and one pair of surrounding quotes.
env_value() {
  local key="$1" file="$2"
  [[ -f "${file}" ]] || { printf ''; return; }
  grep -E "^[[:space:]]*${key}[[:space:]]*=" "${file}" \
    | grep -v '^[[:space:]]*#' \
    | tail -1 \
    | sed -E 's/^[^=]+=//; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/'
}

# Direct overwrite (no temp+rename) keeps the inode stable — Docker
# single-file bind mounts track inodes, so the running container sees
# the new content without a recreate. printf (not echo) avoids a
# trailing newline that the consumer would treat as part of the secret.
write_secret() {
  local path="$1" content="$2" owner="$3" mode="$4"
  printf '%s' "${content}" > "${path}"
  chown "${owner}" "${path}"
  chmod "${mode}" "${path}"
}

# ----------------------------------------------------------------------------
# Grafana admin password (required)
# ----------------------------------------------------------------------------

GF_PASS="$(env_value GRAFANA_ADMIN_PASSWORD "${ENV_FILE}")"
if [[ -z "${GF_PASS}" ]]; then
  err "GRAFANA_ADMIN_PASSWORD is empty in ${ENV_FILE}. Set it and re-run."
  exit 2
fi
if [[ "${#GF_PASS}" -lt 8 ]]; then
  warn "GRAFANA_ADMIN_PASSWORD is shorter than 8 chars. Grafana will accept it; the warning is just to flag weak secrets."
fi

write_secret "${GRAFANA_PASSWORD_FILE}" "${GF_PASS}" "472:472" "0600"
ok "Wrote ${GRAFANA_PASSWORD_FILE} (${#GF_PASS} bytes)"

# Grafana only reads __FILE at process start. If it's already running,
# restarting it is the user's call — log a hint rather than doing it
# behind their back.
if docker ps --filter "name=^pitale-grafana$" --format '{{.Names}}' | grep -q .; then
  info "pitale-grafana is running. Restart to pick up the new password:"
  info "    docker compose -f compose/core.yml restart grafana"
fi

# ----------------------------------------------------------------------------
# SMTP password (optional)
# ----------------------------------------------------------------------------

SMTP_PASS="$(env_value SMTP_PASSWORD "${ENV_FILE}")"
if [[ -z "${SMTP_PASS}" ]]; then
  info "SMTP_PASSWORD is empty in ${ENV_FILE}; skipping the SMTP secret."
  # Remove any stale copy so a previously-configured SMTP no longer
  # has a file lingering with credentials in it.
  if [[ -f "${SMTP_PASSWORD_FILE}" ]]; then
    rm -f "${SMTP_PASSWORD_FILE}"
    warn "Removed stale ${SMTP_PASSWORD_FILE} (SMTP_PASSWORD is now empty)."
  fi
else
  write_secret "${SMTP_PASSWORD_FILE}" "${SMTP_PASS}" "65534:65534" "0600"
  ok "Wrote ${SMTP_PASSWORD_FILE} (${#SMTP_PASS} bytes)"

  if docker ps --filter "name=^pitale-alertmanager$" --format '{{.Names}}' | grep -q .; then
    info "Reloading pitale-alertmanager to pick up the SMTP password…"
    if docker exec pitale-alertmanager wget -qO- --post-data='' http://127.0.0.1:9093/-/reload >/dev/null; then
      ok "Alertmanager reloaded."
    else
      warn "Reload endpoint refused the request. Check 'docker logs pitale-alertmanager'."
    fi
  fi
fi

ok "Done."
