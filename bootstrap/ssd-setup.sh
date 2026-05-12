#!/usr/bin/env bash
# pi-tale — prepare an external SSD for persistent data.
#
# What it does (interactive, idempotent):
#   1. List candidate USB/NVMe block devices.
#   2. Ask the operator to pick one — and confirm twice before touching it.
#   3. Partition (GPT, single ext4 partition) if the device is empty.
#   4. Format ext4 if the partition has no filesystem.
#   5. Add an fstab entry by UUID so it survives reboots.
#   6. Mount it at /mnt/datos.
#   7. (Optional) Move Docker's data-root to /mnt/datos/docker.
#
# ⚠ This script can destroy data. Read every prompt twice.
#
# Status: SKELETON. Implementation will land in a follow-up commit.
# Run scripts/healthcheck.sh after a successful setup.
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run with sudo." >&2
  exit 1
fi

cat <<'EOF'
ssd-setup.sh is not implemented yet.

For now, set up the SSD manually:

  1. Plug it in.                       lsblk
  2. Partition it (GPT, single ext4):  sudo parted /dev/sdX -- mklabel gpt mkpart primary ext4 1MiB 100%
  3. Format:                            sudo mkfs.ext4 -L pi-tale /dev/sdX1
  4. Find the UUID:                     sudo blkid /dev/sdX1
  5. Add to /etc/fstab:                 UUID=<uuid> /mnt/datos ext4 defaults,noatime,nofail 0 2
  6. Mount:                             sudo mkdir -p /mnt/datos && sudo mount -a

Then re-run bootstrap/install.sh.
EOF

exit 0
