#!/usr/bin/env bash
# pi-tale — tune the host for sustained observability workload.
#
# Idempotent. Run after install.sh once the stack is up.
# Status: SKELETON.
#
# Planned actions:
#   - Cap journald disk use (SystemMaxUse=200M, SystemKeepFree=500M).
#   - Disable swap if it lives on the microSD; configure zram if not.
#   - Enable cgroup memory controller (cmdline.txt) — Pi-specific.
#   - Lower vm.swappiness for SSDs (10).
#   - SSH hardening hints (no password root, fail2ban).
#
# All of these will be optional and idempotent.
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run with sudo." >&2
  exit 1
fi

echo "system-tune.sh is not implemented yet. See the file header for the planned actions."
exit 0
