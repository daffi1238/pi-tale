# VPS-side monitoring for pi-tale

This folder is the VPS half of pi-tale's monitoring. Drop these
exporters on any VPS that already peers with the Pi over WireGuard and
its host + container metrics start flowing into Prometheus/Grafana on
the Pi.

```
   ┌──────────── VPS ────────────┐                ┌──── Pi (pi-tale) ────┐
   │  your apps (nginx, …)       │                │                       │
   │                             │  WireGuard     │   Prometheus  Loki    │
   │  node_exporter   :9100      │ ─── scrape ──► │   Grafana, Alertmgr   │
   │  cAdvisor        :9080      │  10.0.0.0/24   │                       │
   │  (nginx_exporter :9113)     │  (encrypted)   │                       │
   │  (postgres_expo  :9187)     │                │                       │
   └─────────────────────────────┘                └───────────────────────┘
```

Total overhead on the VPS: ~150 MB RAM, negligible CPU. All listeners
bind to the WireGuard overlay only — public-facing ports stay
unaffected.

> The recommended first pass deploys just **node_exporter + cAdvisor**.
> Add `nginx_exporter`/`postgres_exporter` later when you actually need
> per-app metrics (they require touching production nginx/Postgres).

## Prerequisites

- WireGuard tunnel already up between the Pi gateway and the VPS.
  - Default overlay: Pi = `10.0.0.125/24`, VPS = `10.0.0.1/24`.
  - Verify the handshake **on the Pi**:
    ```bash
    docker exec pitale-wireguard-gateway wg show wg0
    ```
    Look for `latest handshake: <Xs ago>` with `X < 60` and non-zero
    transfer in both directions.
- Docker + Docker Compose v2 on the VPS.

If you haven't built the tunnel yet, see
[`bootstrap/wireguard-setup.sh`](../../bootstrap/wireguard-setup.sh) on
the Pi side and any `wg-quick` tutorial on the VPS side.

## 1. Get this folder onto the VPS

Use a **sparse clone** so the VPS only fetches what it needs from the
public pi-tale repo:

```bash
git clone --filter=blob:none --sparse https://github.com/daffi1238/pi-tale.git
cd pi-tale
git sparse-checkout set examples/vps-monitoring
cd examples/vps-monitoring
```

Updates later: `git pull && docker compose up -d`.

## 2. Confirm the VPS overlay IP

The exporters bind on the VPS's own WireGuard IP. Confirm it:

```bash
ip -br addr show wg0
# wg0   UNKNOWN   10.0.0.1/24      ← this is your WG_VPS_IP
```

The shipped `.env` already sets `WG_VPS_IP=10.0.0.1`. If your IP is
something else, override it without modifying the tracked file:

```bash
echo 'WG_VPS_IP=10.0.0.X' > .env.local
# docker compose reads .env.local automatically when present
```

## 3. Open the firewall **inbound on wg0**

Even though the exporters bind only on `10.0.0.1`, most VPS hosts run a
default-deny firewall that will drop the scrape requests before they
reach the exporter. Add an explicit ALLOW for the overlay:

```bash
# ufw
sudo ufw allow in on wg0 to any port 9100 proto tcp
sudo ufw allow in on wg0 to any port 9080 proto tcp
sudo ufw reload

# iptables (persist with iptables-persistent)
sudo iptables -I INPUT -i wg0 -p tcp --dport 9100 -j ACCEPT
sudo iptables -I INPUT -i wg0 -p tcp --dport 9080 -j ACCEPT

# nftables
sudo nft insert rule inet filter input iifname "wg0" tcp dport {9100, 9080} accept
```

Public-side rules stay unchanged — the WG bind + this ACCEPT keep the
exporters reachable only from inside the tunnel.

## 4. Bring up node_exporter + cAdvisor

```bash
docker compose up -d node_exporter cadvisor
docker compose ps
```

The other services (`nginx_exporter`, `postgres_exporter`, `promtail`)
stay defined in the YAML but unstarted; ignore the harmless
`POSTGRES_EXPORTER_DSN variable not set` warning, or silence it with:

```bash
echo 'POSTGRES_EXPORTER_DSN=' >> .env.local
```

## 5. Verify (on the VPS)

```bash
# Listeners bind on the WG IP only, not 0.0.0.0
ss -lntp | grep -E '9100|9080'

# Local metrics endpoints respond
curl -s http://10.0.0.1:9100/metrics | head -3
curl -s http://10.0.0.1:9080/metrics | head -3

# Public IP must NOT serve the metrics
curl -s -m 3 http://<public-ip>:9100/metrics   # expect: refused / timeout
```

## 6. Verify (on the Pi)

```bash
curl -sG http://localhost:9090/api/v1/query \
  --data-urlencode 'query=up{job=~"vps_node|vps_cadvisor"}' \
  | python3 -m json.tool
# both jobs should report up = "1"
```

Or open Prometheus at `http://<pi>:9090/targets` and check the
`vps_node` + `vps_cadvisor` rows.

When `up=1` for both, the `VpsNodeDown` alert (if it was firing)
resolves itself in ≤3 min and Telegram sends a `[RESOLVED]`.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `cannot assign requested address` on container start | `WG_VPS_IP` ≠ actual `wg0` IP on the VPS | Run `ip -br addr show wg0`, set the real IP in `.env.local` |
| Containers up, local curl OK, but `up=0` on the Pi | VPS firewall dropping inbound from `wg0` | Add the ACCEPT rules from step 3 |
| `wg show` peers count 0 received bytes | Tunnel not actually established | Check VPS-side wg config + `[Peer]` pubkeys |
| cAdvisor reports `(unhealthy)` | Embedded healthcheck targets port 8080 but we run on 9080 | Add an override (see below) |
| `WARN POSTGRES_EXPORTER_DSN not set` | Compose evaluates all services even when unused | Cosmetic — `echo 'POSTGRES_EXPORTER_DSN=' >> .env.local` |

### cAdvisor healthcheck override

The shipped cAdvisor image embeds a healthcheck pointing at its default
port `8080`. Because we run it on `9080`, the healthcheck always fails
while the service actually works. To fix the cosmetic
`(unhealthy)` state, add to `docker-compose.override.yml`:

```yaml
services:
  cadvisor:
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://127.0.0.1:9080/healthz"]
      interval: 30s
      timeout: 5s
      retries: 3
```

`docker-compose.override.yml` is gitignored, so each VPS can ship its
own tweaks without touching the tracked compose file.

## Adding nginx_exporter / postgres_exporter (second pass)

Both are kept in `docker-compose.yml` but require pre-flight work on the
VPS — that's why they're not in the default first pass.

### nginx

1. Enable `stub_status` in your nginx:
   ```bash
   sudo cp nginx-stub-status.conf /etc/nginx/conf.d/stub_status.conf
   sudo nginx -t && sudo systemctl reload nginx
   curl http://127.0.0.1/stub_status   # sanity check
   ```
2. Open the WG firewall for `9113` (same pattern as step 3).
3. `docker compose up -d nginx_exporter`.

### postgres

1. Create a read-only user:
   ```sql
   CREATE USER pg_monitor WITH PASSWORD 'CHANGE_ME_LONG_RANDOM';
   GRANT pg_monitor TO pg_monitor;   -- pg_monitor is a built-in role since PG 10
   ```
2. Put the DSN in `.env.local` (NEVER in `.env` — `.env` is tracked):
   ```
   POSTGRES_EXPORTER_DSN=postgresql://pg_monitor:THE_PASSWORD@host.docker.internal:5432/postgres?sslmode=disable
   ```
3. Open the WG firewall for `9187`.
4. `docker compose up -d postgres_exporter`.

### Logs to Loki (promtail)

Promtail pushes to `http://10.0.0.125:3100/loki/api/v1/push` (the Pi).
The Pi gateway already DNATs `wg0:3100` to Loki, so no Pi-side change is
needed. Bring it up with `docker compose up -d promtail`. Confirm logs
arrive on the Pi:

```bash
curl -s 'http://localhost:3100/loki/api/v1/labels' | jq '.data'
# should include "host" with values including "vps"
```

## Files

```
docker-compose.yml          all exporters defined; start them à la carte
.env                        tracked: WG_VPS_IP only (non-sensitive)
.env.local                  gitignored: per-VPS overrides + secrets
.env.example                template kept for reference
promtail-config.yml         log shipping to Loki on the Pi
nginx-stub-status.conf      snippet to enable /stub_status on the VPS
README.md                   this file
```
