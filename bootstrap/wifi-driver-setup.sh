#!/usr/bin/env bash
# pi-tale — install the RTL8812AU driver for a USB WiFi adapter.
#
# The Realtek RTL8812AU chipset (USB ID 0bda:8812 — Alfa AWUS036ACH and
# countless clones) is NOT in the mainline kernel, so we build it from
# the upstream DKMS source. DKMS will automatically rebuild it on every
# kernel upgrade, so this script only needs to run once per host.
#
# Targets: Raspberry Pi OS / Debian on Pi hardware with the `rpt`
# kernels (`uname -r` ending in `+rpt-rpi-v8` or `+rpt-rpi-2712`).
#
# Idempotent. Usage:  sudo bootstrap/wifi-driver-setup.sh

set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run with sudo." >&2
  exit 1
fi

# --- Pinned driver source -------------------------------------------------
# morrownr's fork is actively maintained and is the most reliable on
# recent Pi kernels. Pin to a specific commit (not a moving branch) so
# a re-install months from now still produces the same module.
#
# DKMS_NAME matches PACKAGE_NAME inside the upstream dkms.conf — that
# is the identifier `dkms` uses internally. MODULE_NAME is what
# modprobe loads (`BUILT_MODULE_NAME[0]` in dkms.conf). They differ.
DKMS_NAME=rtl8812au
MODULE_NAME=8812au
DRIVER_VERSION=5.13.6
DRIVER_REPO="https://github.com/morrownr/8812au-20210820.git"
# 2026-04-12 "support for kernel 6.14 - .get_tx_power". The commits
# after this one merged a tx-stall patch (PR #62) that references the
# undefined symbol _FW_UNDER_SURVEY and breaks the build — do not
# advance past it without verifying it compiles on Pi rpt kernels.
DRIVER_REF="dabcb74"
SRC_DIR="/usr/src/${DKMS_NAME}-${DRIVER_VERSION}"
LEGACY_SRC_DIR="/usr/src/8812au-${DRIVER_VERSION}"   # from earlier versions of this script

# --- Bail out if already installed ----------------------------------------
if lsmod | awk '{print $1}' | grep -qx "${MODULE_NAME}"; then
  echo "[ok] ${MODULE_NAME} is already loaded — nothing to do."
  echo "     To force a rebuild:"
  echo "       sudo dkms remove ${DKMS_NAME}/${DRIVER_VERSION} --all"
  echo "       sudo rm -rf ${SRC_DIR}"
  exit 0
fi

# --- Pre-flight checks ---------------------------------------------------
KERNEL_REL="$(uname -r)"
case "${KERNEL_REL}" in
  *+rpt-rpi-*) ;;
  *)
    echo "[warn] Running kernel '${KERNEL_REL}' is not a Raspberry Pi rpt kernel."
    echo "       This script targets Pi OS / Debian-on-Pi setups."
    echo "       Continuing anyway — install matching headers manually if it fails."
    ;;
esac

if ! lsusb 2>/dev/null | grep -q "0bda:8812"; then
  echo "[warn] No 0bda:8812 USB device found right now."
  echo "       Continuing — the driver will load once the adapter is plugged in."
fi

# --- Clean up any stale DKMS state from previous attempts -----------------
# Earlier revisions of this script registered the module under the
# wrong DKMS package name (8812au instead of rtl8812au) and cloned the
# source into a non-canonical directory. Wipe both to start clean.
echo "[i] Cleaning up any previous half-installed state..."
for stale_name in 8812au rtl8812au; do
  if dkms status 2>/dev/null | grep -q "^${stale_name}/${DRIVER_VERSION}"; then
    echo "    - removing stale DKMS entry: ${stale_name}/${DRIVER_VERSION}"
    dkms remove "${stale_name}/${DRIVER_VERSION}" --all >/dev/null 2>&1 || true
  fi
done
if [[ -d "${LEGACY_SRC_DIR}" && "${LEGACY_SRC_DIR}" != "${SRC_DIR}" ]]; then
  echo "    - removing legacy source dir: ${LEGACY_SRC_DIR}"
  rm -rf "${LEGACY_SRC_DIR}"
fi

# --- Install build prerequisites -----------------------------------------
echo "[i] Installing build prerequisites (dkms, headers, toolchain)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  dkms bc git build-essential \
  linux-headers-rpi-v8 \
  linux-headers-rpi-2712

# --- Fetch driver source -------------------------------------------------
if [[ ! -d "${SRC_DIR}/.git" ]]; then
  echo "[i] Cloning ${DRIVER_REPO} -> ${SRC_DIR}"
  rm -rf "${SRC_DIR}"
  git clone "${DRIVER_REPO}" "${SRC_DIR}"
fi

git -C "${SRC_DIR}" fetch --quiet
git -C "${SRC_DIR}" -c advice.detachedHead=false checkout --quiet "${DRIVER_REF}"

# Normalise PACKAGE_VERSION in dkms.conf so it matches what we use
# below for `dkms build` / `dkms install`. Upstream sometimes ships a
# different value and any inconsistency breaks the build.
sed -i -E "s/^PACKAGE_VERSION=.*/PACKAGE_VERSION=\"${DRIVER_VERSION}\"/" "${SRC_DIR}/dkms.conf"

# --- DKMS add / build / install ------------------------------------------
echo "[i] Registering with DKMS as ${DKMS_NAME}/${DRIVER_VERSION}..."
dkms add "${SRC_DIR}"

echo "[i] Building module (this can take a couple of minutes on a Pi)..."
dkms build "${DKMS_NAME}/${DRIVER_VERSION}"

echo "[i] Installing module..."
dkms install "${DKMS_NAME}/${DRIVER_VERSION}"

# --- Load and verify -----------------------------------------------------
echo "[i] Loading module..."
modprobe "${MODULE_NAME}"

echo
echo "[ok] Driver installed and loaded:"
lsmod | grep "${MODULE_NAME}" || true
echo
echo "----- iw dev -----"
sleep 2   # give udev a moment to bring up the new netdev
iw dev || true
echo "------------------"
echo
echo "If you see a new wlanN interface above, the adapter is ready."
echo "If not, unplug and replug the antenna, then re-run:  iw dev"
