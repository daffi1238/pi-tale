#!/usr/bin/env bash
# pi-tale — render the Alertmanager config from its template and install
# the Telegram bot token, from values held in compose/.env.
#
# Two things happen here:
#
#   1. The Telegram bot TOKEN is written to a file outside the YAML
#      (alertmanager v0.27+ reads it via `bot_token_file`). Secrets stay
#      off disk in plain config and off any committed file.
#
#   2. The Telegram CHAT ID is substituted into the rendered config at
#      `data/alertmanager/runtime/alertmanager.yml`. We render from the
#      committed template `alertmanager/alertmanager.yml.tmpl` so the
#      single source of truth for per-install personal values is
#      compose/.env.
#
# Both steps preserve inodes on re-run so a `make reload-alertmanager`
# picks the changes up without recreating the container (Docker's
# single-file bind mounts track inodes, not paths).
#
# Usage:
#   sudo scripts/telegram-setup.sh                    # read both from compose/.env
#   sudo scripts/telegram-setup.sh <token>            # token from argv, chat id from .env
#   sudo scripts/telegram-setup.sh <token> <chat_id>  # both from argv
#
# Exit codes:
#   0  ok
#   1  generic failure
#   2  pre-flight failure (no .env, missing values, wrong perms)

set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Logging (matches bootstrap/install.sh)
# ----------------------------------------------------------------------------

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_BLUE=$'\033[34m'
else
  C_RESET=""
  C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""
fi

info()    { printf '%s[i]%s %s\n'  "${C_BLUE}"   "${C_RESET}" "$*"; }
ok()      { printf '%s[ok]%s %s\n' "${C_GREEN}"  "${C_RESET}" "$*"; }
warn()    { printf '%s[!]%s  %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
err()     { printf '%s[x]%s  %s\n' "${C_RED}"    "${C_RESET}" "$*" >&2; }

trap 'err "telegram-setup.sh failed on line $LINENO."' ERR

# ----------------------------------------------------------------------------
# Pre-flight
# ----------------------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
  err "Run with sudo. The target files live in directories owned by uid 65534."
  err "  sudo scripts/telegram-setup.sh"
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV_FILE="${REPO_ROOT}/compose/.env"
SECRETS_DIR="${REPO_ROOT}/data/alertmanager/secrets"
TOKEN_FILE="${SECRETS_DIR}/telegram_bot_token"

RUNTIME_DIR="${REPO_ROOT}/data/alertmanager/runtime"
TEMPLATE_FILE="${REPO_ROOT}/alertmanager/alertmanager.yml.tmpl"
RUNTIME_FILE="${RUNTIME_DIR}/alertmanager.yml"

if [[ ! -f "${TEMPLATE_FILE}" ]]; then
  err "Template not found: ${TEMPLATE_FILE}"
  exit 2
fi

for d in "${SECRETS_DIR}" "${RUNTIME_DIR}"; do
  if [[ ! -d "${d}" ]]; then
    # bootstrap/install.sh creates these with the right ownership. If
    # missing we create them, but flag the install script as the
    # canonical path.
    mkdir -p "${d}"
    chown 65534:65534 "${d}"
    chmod 0750 "${d}"
    warn "Created ${d}. Re-run bootstrap/install.sh for the canonical perms."
  fi
done

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

# Extract the last non-commented value of a key from a KEY=VALUE file.
# Trims surrounding whitespace and a single pair of quotes (single or
# double). Empty string on miss.
env_value() {
  local key="$1" file="$2"
  [[ -f "${file}" ]] || { printf ''; return; }
  grep -E "^[[:space:]]*${key}[[:space:]]*=" "${file}" \
    | grep -v '^[[:space:]]*#' \
    | tail -1 \
    | sed -E 's/^[^=]+=//; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/'
}

# ----------------------------------------------------------------------------
# Resolve token and chat id (argv > env file)
# ----------------------------------------------------------------------------

TOKEN="${1:-}"
CHAT_ID="${2:-}"

[[ -z "${TOKEN}"   ]] && TOKEN="$(env_value TELEGRAM_BOT_TOKEN "${ENV_FILE}")"
[[ -z "${CHAT_ID}" ]] && CHAT_ID="$(env_value TELEGRAM_CHAT_ID "${ENV_FILE}")"

if [[ -z "${TOKEN}" ]]; then
  err "TELEGRAM_BOT_TOKEN is empty in ${ENV_FILE} and no token was passed."
  err "  - get one from @BotFather, set it in compose/.env, and re-run."
  exit 2
fi

if [[ -z "${CHAT_ID}" ]]; then
  err "TELEGRAM_CHAT_ID is empty in ${ENV_FILE} and no chat id was passed."
  err "  - find it with:"
  err "      curl -s 'https://api.telegram.org/bot<token>/getUpdates' | jq '.result[].message.chat'"
  err "    (negative for groups; positive for DM to the user)."
  exit 2
fi

# Shape checks. BotFather tokens look like '<int>:<base64-ish>'.
if [[ ! "${TOKEN}" =~ ^[0-9]+:[A-Za-z0-9_-]{20,}$ ]]; then
  err "Token does not look like a Telegram bot token (expected '<digits>:<rest>')."
  err "Got: ${TOKEN:0:8}…  (${#TOKEN} chars)"
  exit 2
fi

# Chat id: optional leading minus, then digits. 0 is rejected by amtool.
if [[ ! "${CHAT_ID}" =~ ^-?[1-9][0-9]*$ ]]; then
  err "Chat id is not a non-zero integer: '${CHAT_ID}'"
  exit 2
fi

# ----------------------------------------------------------------------------
# Write the token file (inode preserved if it existed)
# ----------------------------------------------------------------------------

# `printf` (not echo + redirect) so we never accidentally append a newline
# that some parsers would mistake for part of the secret.
#
# We DELIBERATELY write directly to the destination instead of mktemp+mv:
# Docker bind mounts of a single file track the inode, so a rename would
# leave the running alertmanager pointed at the old (now orphaned) inode
# until the container is recreated. Direct overwrite keeps the inode.
printf '%s' "${TOKEN}" > "${TOKEN_FILE}"
chown 65534:65534 "${TOKEN_FILE}"
chmod 0600 "${TOKEN_FILE}"
ok "Wrote ${TOKEN_FILE} (${#TOKEN} bytes)"

# ----------------------------------------------------------------------------
# Render the alertmanager.yml from the template
# ----------------------------------------------------------------------------

# Substitution is intentionally minimal — one named placeholder, plain
# sed. No envsubst, no Go template engine in front of the alertmanager
# YAML (which itself uses Go template syntax for the message body and
# would conflict with envsubst's `${}`).
RENDERED="$(sed -E "s|__TELEGRAM_CHAT_ID__|${CHAT_ID}|g" "${TEMPLATE_FILE}")"

if [[ -z "${RENDERED}" ]] || ! grep -q "chat_id: ${CHAT_ID}" <<<"${RENDERED}"; then
  err "Template render failed — refusing to overwrite ${RUNTIME_FILE}."
  exit 1
fi

# Same direct-overwrite rationale as the token file above.
printf '%s\n' "${RENDERED}" > "${RUNTIME_FILE}"
chown 65534:65534 "${RUNTIME_FILE}"
chmod 0640 "${RUNTIME_FILE}"
ok "Rendered ${RUNTIME_FILE} (chat_id=${CHAT_ID})"

# ----------------------------------------------------------------------------
# Reload alertmanager if it is running
# ----------------------------------------------------------------------------

if docker ps --filter "name=^pitale-alertmanager$" --format '{{.Names}}' | grep -q .; then
  info "Reloading pitale-alertmanager…"
  if docker exec pitale-alertmanager wget -qO- --post-data='' http://127.0.0.1:9093/-/reload >/dev/null; then
    ok "Alertmanager reloaded."
  else
    warn "Reload endpoint refused the request. Check 'docker logs pitale-alertmanager'."
  fi
else
  info "pitale-alertmanager is not running; will pick up both files on next start."
fi
