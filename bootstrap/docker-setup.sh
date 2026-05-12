#!/usr/bin/env bash
# pi-tale — install Docker Engine and the compose plugin on Debian-based
# systems (Raspberry Pi OS Bookworm, Debian 12). Idempotent.
#
# Usage: sudo bootstrap/docker-setup.sh
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run with sudo." >&2
  exit 1
fi

# Already there? Nothing to do.
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  echo "Docker and compose plugin already installed; skipping."
  exit 0
fi

. /etc/os-release || { echo "Cannot read /etc/os-release."; exit 1; }
ID_LOWER="${ID,,}"
CODENAME="${VERSION_CODENAME:-}"

case "${ID_LOWER}" in
  raspbian|debian|raspberrypi-os|ubuntu) ;;
  *)
    echo "Unsupported distribution '${ID_LOWER}'. Install Docker manually:"
    echo "  https://docs.docker.com/engine/install/"
    exit 1
    ;;
esac

# Raspberry Pi OS reports itself as "debian" via /etc/os-release; that is
# what Docker's repository expects, so we always pass "debian" here.
DOCKER_DISTRO="debian"

echo "[i] Installing Docker for ${DOCKER_DISTRO} ${CODENAME}..."

apt-get update
apt-get install -y ca-certificates curl gnupg lsb-release

install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
fi

cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DOCKER_DISTRO} ${CODENAME} stable
EOF

apt-get update
apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

systemctl enable --now docker

echo "[ok] Docker installed: $(docker --version)"
echo "[ok] Compose plugin:   $(docker compose version --short)"
