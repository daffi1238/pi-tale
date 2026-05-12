#!/usr/bin/env bash
# pi-tale — quick health check.
# Walks through the core services and reports whether their HTTP health
# endpoints are responding. Exits non-zero if any check fails.
#
# Usage: scripts/healthcheck.sh
set -Eeuo pipefail

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'
else
  C_RESET=""; C_GREEN=""; C_RED=""; C_YELLOW=""
fi

PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
ALERTMANAGER_PORT="${ALERTMANAGER_PORT:-9093}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"
LOKI_PORT="${LOKI_PORT:-3100}"
CADVISOR_PORT="${CADVISOR_PORT:-8081}"

# (label, url)
declare -a CHECKS=(
  "prometheus|http://127.0.0.1:${PROMETHEUS_PORT}/-/healthy"
  "alertmanager|http://127.0.0.1:${ALERTMANAGER_PORT}/-/healthy"
  "grafana|http://127.0.0.1:${GRAFANA_PORT}/api/health"
  "loki|http://127.0.0.1:${LOKI_PORT}/ready"
  "cadvisor|http://127.0.0.1:${CADVISOR_PORT}/healthz"
)

fail=0
for entry in "${CHECKS[@]}"; do
  IFS='|' read -r name url <<<"${entry}"
  printf '%-14s ' "${name}"
  if curl -fsS --max-time 5 "${url}" >/dev/null; then
    printf '%sOK%s\n' "${C_GREEN}" "${C_RESET}"
  else
    printf '%sDOWN%s   (%s)\n' "${C_RED}" "${C_RESET}" "${url}"
    fail=1
  fi
done

if [[ "${fail}" -ne 0 ]]; then
  printf '\n%shealthcheck: at least one service is unhealthy%s\n' "${C_YELLOW}" "${C_RESET}" >&2
  exit 1
fi
