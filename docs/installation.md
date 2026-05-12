# Installation

This page is the long form of the README quickstart. If something fails,
look at [`troubleshooting.md`](troubleshooting.md) first.

## Prerequisites

- Raspberry Pi 4 (4 GB or 8 GB) or Raspberry Pi 5 (4/8/16 GB).
- microSD card (16 GB+) for boot.
- USB 3.0 SSD (60 GB+) or NVMe via HAT (recommended: 256 GB+).
- Wired Ethernet to your UniFi network during installation.
- Raspberry Pi OS Lite 64-bit (Bookworm) freshly flashed.

## 1. Prepare the OS

Use `rpi-imager` to flash Raspberry Pi OS Lite (64-bit). In the imager's
advanced options:

- Set a hostname (`pi-tale` is a good default).
- Enable SSH with a real password or your public key.
- Set locale and timezone.

Boot the Pi, SSH in, then update the system:

```bash
sudo apt update && sudo apt full-upgrade -y && sudo reboot
```

## 2. Clone the repo

```bash
sudo apt install -y git
git clone https://github.com/daffi1238/pi-tale.git
cd pi-tale
```

## 3. Prepare the SSD

Plug the SSD in **before** running the next step.

```bash
sudo bootstrap/ssd-setup.sh
```

> Status: the script is currently a guided walkthrough — implementation
> in progress. Until it lands, follow the steps printed by the script to
> partition, format and mount the SSD at `/mnt/datos`.

## 4. Run the installer

```bash
sudo bootstrap/install.sh
```

What it does:

- Detects whether you are on a Pi (warns otherwise).
- Installs Docker + the compose plugin if missing.
- Verifies `/mnt/datos` is mounted (warns otherwise).
- Creates `./data/<service>` with the right ownership for each container.
- Copies `compose/.env.example` to `compose/.env` if it doesn't exist.
- Prints the next steps.

The installer is idempotent; running it again after changes is fine.

## 5. Configure secrets

Edit `compose/.env`. The only **required** field is
`GRAFANA_ADMIN_PASSWORD` — compose will refuse to start without it.

Everything else (Telegram bot token, SMTP credentials, ports, retention)
has sensible defaults.

## 6. Start the stack

```bash
docker compose -f compose/core.yml --env-file compose/.env up -d
docker compose -f compose/core.yml --env-file compose/.env ps
```

Open Grafana on `http://<pi-ip>:3000` with user `admin` and the password
you set above.

## 7. (Optional) Tune the host

```bash
sudo bootstrap/system-tune.sh
```

Lower journald disk use, enable zram, tweak swappiness, harden SSH.
Currently a skeleton — see the file header for the planned actions.

## Updating

```bash
git pull
docker compose -f compose/core.yml --env-file compose/.env pull
docker compose -f compose/core.yml --env-file compose/.env up -d
```

Image tags are pinned in the compose files — `pull` only fetches new
content if a maintainer bumped a version in this repo.
