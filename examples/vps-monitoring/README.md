# VPS-side monitoring for pi-tale

This folder is the VPS half of pi-tale's monitoring setup. It runs four
Prometheus exporters and Promtail behind a WireGuard tunnel so nothing
about your VPS's internals is exposed to the public internet.

```
  Internet ┐
           │  HTTPS to your apps (unchanged)
           ▼
   ┌──────────────── VPS ────────────────┐                ┌──── Pi (pi-tale) ────┐
   │                                     │   WireGuard    │                       │
   │  apps (TwinTongues, WP, Postgres)   │ ───────────►   │   Prometheus  Loki    │
   │  + node_exporter, cAdvisor, nginx,  │  10.50.0.0/24  │   Grafana, Alertmgr   │
   │    postgres exporter, Promtail      │  (encrypted)   │   Telegram alerts     │
   └─────────────────────────────────────┘                └───────────────────────┘
```

Total VPS overhead: ~150 MB RAM, negligible CPU. All listeners bind to
the WG overlay only — `0.0.0.0:9100/9080/9113/9187` are NOT exposed.

## 1. Bring up the WireGuard tunnel

On the **VPS**, configure WireGuard (any standard `wg-quick` setup
works) and register the Pi gateway's public key as a `[Peer]`. The Pi
side is a client — no public IP needed.

On the **Pi**, drop a fully-formed `wg0.conf` at
`data/wireguard/wg0.conf` (mode 0600, root-owned). See
`data/wireguard/wg0.conf.example` for the expected shape — at minimum
you set the Pi's private key, the VPS public key, the VPS endpoint, and
`AllowedIPs` restricted to the overlay (e.g. `10.50.0.0/24`). Make
sure `WG_PI_IP` and `WG_VPS_IP` in `compose/.env` match what the conf
assigns and what you want to scrape on the VPS — the gateway's DNAT
rules use them.

Then start the gateway and verify the handshake:

```bash
make wireguard
make wireguard-status
```

## 2. Deploy the exporters on the VPS

```bash
# Copy this whole folder to the VPS, e.g.
scp -r examples/vps-monitoring/ vps:/opt/pitale-vps-monitoring/
ssh vps

cd /opt/pitale-vps-monitoring
cp .env.example .env
nano .env                       # edit POSTGRES_EXPORTER_DSN at minimum

docker compose --env-file .env up -d
docker compose ps
```

You should see five containers running: `pitale-vps-node-exporter`,
`pitale-vps-cadvisor`, `pitale-vps-nginx-exporter`,
`pitale-vps-postgres-exporter`, `pitale-vps-promtail`.

From the **Pi**, verify each is scrapeable over WG:

```bash
curl -s http://10.50.0.2:9100/metrics  | head     # node
curl -s http://10.50.0.2:9080/metrics  | head     # cadvisor
curl -s http://10.50.0.2:9113/metrics  | head     # nginx
curl -s http://10.50.0.2:9187/metrics  | head     # postgres
```

## 3. Pre-flight on the VPS

### nginx stub_status

`nginx_exporter` needs nginx's `stub_status` endpoint enabled. Drop
`nginx-stub-status.conf` from this folder into
`/etc/nginx/conf.d/stub_status.conf` and reload:

```bash
sudo cp nginx-stub-status.conf /etc/nginx/conf.d/stub_status.conf
sudo nginx -t && sudo systemctl reload nginx
curl http://127.0.0.1/stub_status   # sanity check
```

The block listens on `127.0.0.1:80` only. The exporter talks to it via
`host.docker.internal` from inside its container.

### Postgres read-only user

Connect to Postgres as a superuser and create a monitoring role:

```sql
CREATE USER pg_monitor WITH PASSWORD 'CHANGE_ME_LONG_RANDOM';
-- pg_monitor is a built-in role since Postgres 10 that grants
-- read access to pg_stat_* views without GRANTing on real tables.
GRANT pg_monitor TO pg_monitor;
```

Then put the credentials in the VPS's `.env`:

```
POSTGRES_EXPORTER_DSN=postgresql://pg_monitor:THE_PASSWORD@host.docker.internal:5432/postgres?sslmode=disable
```

If your Postgres listens on a non-default host/port, adjust accordingly.
If Postgres is itself in a Docker container, use the container hostname
or the docker bridge IP instead of `host.docker.internal`.

### Promtail → Loki

Promtail pushes to `http://10.50.0.1:3100/loki/api/v1/push` (the Pi over
WG). The Pi's Loki container already publishes `:3100` on `0.0.0.0`, so
no Pi-side change is needed; just make sure the tunnel is up.

To confirm logs are arriving, on the Pi:

```bash
curl -s 'http://localhost:3100/loki/api/v1/labels' | jq
# Should include `host` in the labels list, with values pi-tale-node AND vps.
```

## 4. Activate the scrapes on the Pi

The target files at `prometheus/targets/vps-*-main.yml` already have
`10.50.0.2:<port>` in them, so a Prometheus reload is enough:

```bash
make reload-prometheus
```

In Prometheus's `/targets` page you should now see `vps_node`,
`vps_cadvisor`, `vps_nginx`, `vps_postgres` and `wireguard_exporter` all
green.

## 5. Firewall hardening (recommended)

Even though the exporters bind to the WG interface, set explicit drops
on the public interface so a misconfiguration can't accidentally expose
them:

```bash
# Allow WireGuard in
sudo ufw allow 51820/udp
# Implicit deny on everything else (assuming ufw default is deny)
sudo ufw status verbose
```

## Files

```
docker-compose.yml          all five containers
.env.example                template — copy to .env
promtail-config.yml         log shipping to Loki on the Pi
nginx-stub-status.conf      enables /stub_status on localhost
README.md                   this file
```
