# Migrating the pi-tale observability ingestor

Everything needed to rebuild this ingestor on another machine is either in
this git repo (config as code) or must be re-supplied out-of-band (secrets
and state, which are gitignored). This is the recipe.

## What lives where

| Category | Where | In git? |
|---|---|---|
| Compose files, exporter/dashboard/rule/config | this repo | ✅ yes |
| Secrets (`compose/.env`, `data/*/secrets/`, WG keys) | `compose/.env`, `data/` | ❌ gitignored — re-supply |
| State/history (Prometheus TSDB, Loki chunks, Grafana db, UniFi) | `data/` | ❌ gitignored — optional to carry over |

Secrets and `data/` are deliberately **not** committed (see `.gitignore`:
`/data/`, `compose/.env`). Never force them in.

## Prerequisites on the new host

- Docker + Docker Compose plugin, enabled at boot (`systemctl enable docker`).
- The data dir on real storage (SSD), not the SD card. This repo expects
  `../data` relative to `compose/` — mirror the existing layout, e.g.
  `/mnt/datos/pi-tale` with a symlink `~/pi-tale -> /mnt/datos/pi-tale`.
- WireGuard kernel module available (containerised gateway uses it).

## Steps

1. **Clone the repo**
   ```bash
   git clone git@github.com:daffi1238/pi-tale.git /mnt/datos/pi-tale
   cd /mnt/datos/pi-tale
   ```

2. **Recreate `compose/.env`** from the template and fill in the secrets:
   ```bash
   cp compose/.env.example compose/.env && nano compose/.env
   ```
   Key values: `BIND_HOST=127.0.0.1`, `WG_PI_IP`/`WG_VPS_IP`,
   `GRAFANA_ADMIN_PASSWORD`, `TELEGRAM_BOT_TOKEN`/`TELEGRAM_CHAT_ID`,
   the UniFi/Mongo passwords, `PROMETHEUS_RETENTION=30d`.

3. **Recreate the WireGuard config** (private key — never in git):
   ```bash
   sudo mkdir -p data/wireguard
   sudo cp /path/to/your/wg0.conf data/wireguard/wg0.conf   # mode 0600, root
   ```
   See `data/wireguard/wg0.conf.example` for the shape. `AllowedIPs` must be
   the overlay subnet (e.g. `10.0.0.0/24`), **never** `0.0.0.0/0`.

4. **Render the file-based secrets** (Grafana admin password, Telegram bot
   token, Alertmanager runtime config):
   ```bash
   sudo make secrets-setup     # from GRAFANA_ADMIN_PASSWORD etc. in .env
   sudo make telegram-setup    # renders alertmanager runtime + token file
   ```

5. **Bring the stack up** (each compose file is its own project — the
   Makefile wraps the right `-f`/order):
   ```bash
   make up          # core: prometheus, loki, grafana, alertmanager, blackbox, promtail, node, cadvisor
   make wireguard   # the WG gateway (must start after core — pitale net is external)
   make probes extras tls unifi   # optional stacks, as needed
   ```

6. **Verify**
   ```bash
   make ps
   make validate                     # promtool/amtool config checks
   ss -ltnp | grep -E ':3000|:9090|:3100'   # must be 127.0.0.1, never 0.0.0.0
   ```
   Then open Grafana at `http://<WG_PI_IP>:3000` (via the gateway ingress)
   or `localhost:3000` over an SSH tunnel.

## Carrying over history (optional)

To keep past metrics/logs instead of starting fresh, copy the relevant
`data/` subdirs from the old host while the stack is **down**:
`data/prometheus`, `data/loki`, `data/grafana`, `data/alertmanager`,
`data/unifi`. Or use the built-in `make backup` / `make restore`.

## The other half: the VPS agent

This repo is the **ingestor** (the Pi, `10.0.0.125`). The **VPS side**
(exporters + Grafana Alloy that this ingestor pulls from / receives push
from) is a separate deployment. Its reference lives under
`examples/vps-monitoring/` (node/cadvisor/nginx exporters, `alloy/` log
shipper). See `examples/vps-monitoring/INGESTOR-HANDOFF.md` for what the VPS
must run and how it addresses the overlay (push logs to `10.0.0.125:3100`,
expose exporters on `10.0.0.1:<port>`).
