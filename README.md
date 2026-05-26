<p align="center">
  <!-- TODO: replace with real logo at docs/images/logo.png -->
  <img src="docs/images/logo.png" alt="pi-tale logo" width="160" onerror="this.style.display='none'"/>
</p>

<h1 align="center">pi-tale</h1>

<p align="center">
  <em>your raspberry pi, your network's whistleblower</em>
</p>

<p align="center">
  <a href="#status"><img src="https://img.shields.io/badge/status-early%20development-orange" alt="status"/></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-blue" alt="license"/></a>
  <a href="https://github.com/daffi1238/pi-tale/actions/workflows/ci.yml"><img src="https://github.com/daffi1238/pi-tale/actions/workflows/ci.yml/badge.svg?branch=main" alt="ci"/></a>
  <img src="https://img.shields.io/badge/arch-arm64-success" alt="arch"/>
  <img src="https://img.shields.io/badge/runs%20on-Raspberry%20Pi%204%2F5-c51a4a" alt="runs on Pi"/>
</p>

---

## Why pi-tale?

Professional network monitoring stacks were built for data centers: they are
expensive, heavy, and overkill for the kind of network most small businesses
actually run. Small hotels, offices, restaurants and serious homelabs end up
with no observability at all — until users complain that "the WiFi is slow"
or "the cameras went offline last night".

**pi-tale** is the opposite philosophy:

- A single Raspberry Pi 4 or 5 is enough.
- One bootstrap script, less than an hour to a working dashboard.
- No SaaS, no licenses, no phone-home telemetry.
- Tailored to **Ubiquiti UniFi** networks (3–20 PoE devices) without locking
  you into them.
- Everything in Docker Compose, reproducible and portable.

If you already operate a UniFi-based network and you want to see *what is
actually happening* on it — PoE budgets, AP load, DHCP health, sticky
clients, latency to your gateway and to the open internet, link flaps,
container health, host temperature — pi-tale is the smallest stack that
gets you there.

## Status

🚧 **Early development.** APIs, layout and defaults will change. The
repository is being built in the open; expect the `main` branch to move.
The `CHANGELOG.md` tracks user-visible changes following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Quickstart

> The flow below is the **target experience**. Some pieces are still being
> implemented — see [Status](#status) and `CHANGELOG.md`.

On a Raspberry Pi 4 (4 GB+) or Pi 5 running **Raspberry Pi OS Lite 64-bit
(Bookworm)** with an SSD attached over USB 3.0 or NVMe:

```bash
# 1. Clone
git clone https://github.com/daffi1238/pi-tale.git
cd pi-tale

# 2. Prepare the SSD (idempotent: safe to re-run)
sudo bootstrap/ssd-setup.sh        # partitions, mounts to /mnt/datos, points Docker there

# 3. Install Docker, tune the system, create folders, copy .env
sudo bootstrap/install.sh

# 4. Edit .env with your secrets (Grafana admin password, Telegram token, SMTP, ...)
nano compose/.env

# 5. Bring up the core stack
make up

# 6. Open Grafana
#    http://<pi-ip>:3000   (default user: admin, password: from .env)
```

Additional layers are independent compose projects — bring them up
**alongside** core (not stacked with `-f`, each one has its own
project name):

```bash
make probes    # WiFi RF exporter
make extras    # Uptime Kuma
make unifi     # UniFi controller + poller (stub for now)
make all       # core + probes + extras in one go
```

`make help` lists every target (`up`, `down`, `ps`, `logs SERVICE=x`,
`pull`, `build`, `backup`, `restore ARCHIVE=...`, ...). The raw
`docker compose` invocations behind each target are documented in
[`Makefile`](Makefile) if you prefer to run them by hand.

Full installation walkthrough: [`docs/installation.md`](docs/installation.md).

## Architecture

```
                              ┌──────────────────────────┐
                              │  Operator's browser      │
                              │  (Grafana / Uptime Kuma) │
                              └─────────────┬────────────┘
                                            │ :3000 / :3001
                                            ▼
 ┌─────────────────────────── Raspberry Pi (pi-tale node) ────────────────────────────┐
 │                                                                                    │
 │   ┌────────────┐   ┌────────────┐   ┌──────────────┐   ┌──────────────────────┐    │
 │   │  Grafana   │◄──┤ Prometheus │◄──┤ Alertmanager │──►│ Telegram / SMTP      │    │
 │   └────┬───────┘   └─────┬──────┘   └──────────────┘   └──────────────────────┘    │
 │        │ logs            │ scrape                                                  │
 │        ▼                 ▼                                                         │
 │   ┌──────────┐    ┌───────────────┐  ┌───────────────┐  ┌───────────────┐          │
 │   │   Loki   │◄───┤   Promtail    │  │ node_exporter │  │   cAdvisor    │          │
 │   └──────────┘    └───────────────┘  └───────────────┘  └───────────────┘          │
 │                                                                                    │
 │   ┌──────────────────┐   ┌──────────────┐   ┌─────────────────┐                    │
 │   │ blackbox_exporter│   │ snmp_exporter│   │ unifi-poller    │                    │
 │   └────────┬─────────┘   └──────┬───────┘   └────────┬────────┘                    │
 │            │ probes              │ SNMP              │ UniFi API                   │
 └────────────┼─────────────────────┼───────────────────┼─────────────────────────────┘
              ▼                     ▼                   ▼
        Internet / LAN         Switches/UPS        UniFi controller
        (HTTP, ICMP, TCP)      (SNMP v2c/v3)       (USG/UDM, APs, switches)

                                  ┌────────────────────────────┐
                                  │ WiFi probe (Alfa adapter)  │  optional
                                  │ Python exporter: iw scan   │
                                  └────────────────────────────┘
```

A deeper write-up lives in [`docs/architecture.md`](docs/architecture.md).

## What pi-tale watches out of the box

- **Host health** — CPU, memory, disk, temperature, throttling
  (`node_exporter`).
- **Stack health** — container CPU/memory, restarts (`cAdvisor`).
- **Reachability** — intranet hosts, gateway, public DNS, your favourite
  websites (`blackbox_exporter`, ICMP/HTTP/TCP probes).
- **Logs** — syslog and container logs centralised in Loki via Promtail.
- **Alerts** — Telegram and email (SMTP) receivers in Alertmanager, both
  off by default, enabled by filling in `.env`.

Adding UniFi metrics, SNMP devices and WiFi RF sondas is done by enabling
the corresponding compose layer; see the docs.

## Monitoring a remote VPS

pi-tale can scrape host and container metrics from any VPS that joins
its WireGuard overlay — useful when you run apps on a public-internet
server but want their resource usage shown next to the rest of your
infrastructure. Nothing about the VPS internals is exposed publicly:
the exporters bind only on the WireGuard interface.

```
   ┌──────── VPS ────────┐                  ┌──── Pi (pi-tale) ────┐
   │ apps + node_exp +   │ ─── WireGuard ── │  Prometheus  Loki    │
   │ cAdvisor (+ nginx,  │   10.0.0.0/24    │  Grafana, Alertmgr   │
   │ postgres exporters) │   (encrypted)    │                       │
   └─────────────────────┘                  └───────────────────────┘
```

Full walkthrough (sparse clone, firewall, first-pass + opt-in
exporters, troubleshooting): [`examples/vps-monitoring/README.md`](examples/vps-monitoring/README.md).

## Optional: Uptime Kuma UI

If you (or whoever else has to look at this dashboard) want a friendlier
way to add monitors and tweak notifications without editing YAML, enable
the **extras** layer:

```bash
make extras
```

Then open `http://<pi-ip>:3001` and create the admin user on first
visit. Kuma manages its own checks (ping, HTTP, TCP, DNS, …) and its
own notifications independently of Prometheus/Alertmanager — see
[`docs/targets/uptime-kuma.md`](docs/targets/uptime-kuma.md) for when
to use which.

## Backup and restore

The bind-mounted `data/` directory holds everything that matters across
reboots: Prometheus TSDB, Loki chunks, Grafana SQLite, Alertmanager
silences. `scripts/backup.sh` packages it all into a date-stamped
tarball with rotation; `scripts/restore.sh` puts a tarball back in
place. Both stop and restart only the compose projects that are
actually running.

```bash
# Default: stop running stacks, tar ./data, restart, keep the 7 newest
sudo scripts/backup.sh

# Save somewhere off the Pi (recommended once you have a USB or NAS mount)
sudo BACKUP_DIR=/mnt/usb/pi-tale-backups scripts/backup.sh

# Restore a specific archive (moves the current ./data aside first)
sudo scripts/restore.sh backup/pi-tale-backup-20260516-1200Z.tar.gz
```

See `scripts/backup.sh --help` for `--live`, `--include-env` and
`--dest` flags.

## Hardware

See [`docs/hardware.md`](docs/hardware.md) for the recommended bill of
materials. Short version: Pi 4 / Pi 5, **never put data on the microSD** —
use an SSD over USB 3.0 or an NVMe HAT.

## Contributing

Issues, ideas and PRs are welcome. Read
[`CONTRIBUTING.md`](CONTRIBUTING.md) for the basics.

## License

Apache 2.0 — see [`LICENSE`](LICENSE).
