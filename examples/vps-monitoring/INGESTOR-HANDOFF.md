# VPS side — what's left to do (handoff from the ingestor)

The ingestor (this Pi, `10.0.0.125` on WireGuard) is configured and running.
This file lists the correlated work that must happen **on the VPS** for the
remaining signals to light up. The overlay is already up and metrics for
`node`/`cadvisor` are flowing; the items below add nginx, logs and file
auditing.

## Overlay addressing (correct these in the VPS compose/.env)

The `examples/vps-monitoring/docker-compose.yml` defaults assume subnet
`10.50.0.0/24`. The **real** overlay is:

- VPS  = `10.0.0.1`   → set `WG_VPS_IP=10.0.0.1`
- Pi   = `10.0.0.125` → Alloy/Promtail push target `http://10.0.0.125:3100`

All VPS exporters must bind on `10.0.0.1` (never `0.0.0.0`).

## 1. nginx metrics (fixes Prometheus `vps_nginx` = DOWN)

- Enable `stub_status` in nginx — see `nginx-stub-status.conf` in this folder.
- Run `nginx_exporter` (already in the VPS compose) pointed at it, listening
  on `10.0.0.1:9113`. The ingestor already scrapes `wireguard_gateway:9113`,
  which DNATs to `10.0.0.1:9113`.

## 2. postgres metrics (optional; fixes `vps_postgres` = DOWN)

- Only if you run Postgres on the VPS. Start `postgres_exporter` on
  `10.0.0.1:9187` with a valid `DATA_SOURCE_NAME`. Leave it off otherwise —
  there is no alert paging for nginx/postgres being down yet (deliberate).

## 3. Logs → Loki (SSH alerts + nginx/ssh/auditd dashboards)

Run **Grafana Alloy** (or Promtail) on the VPS shipping to
`http://10.0.0.125:3100/loki/api/v1/push`, and label streams with
`host="vps"` (the ingestor's rules and dashboards filter on `host=~"vps.*"`).

Ship at minimum:

- Docker container logs (nginx reverse proxy access/error).
- **sshd auth** — on modern Debian/Ubuntu this is `/var/log/auth.log` **or**
  the systemd journal, NOT `/var/log/syslog`. Make sure Alloy reads the file
  that actually carries `sshd` lines, or the SSH alerts never fire.

Once `host="vps"` sshd logs arrive, these alerts (already loaded on the Pi,
currently `inactive`) start evaluating:

- `SSHBruteForce`  — >10 `Failed password`/`Invalid user` in 5m (critical)
- `SSHAcceptedLogin` — any `Accepted` login in 5m (info)

## 4. auditd (file read/write auditing)

Install `auditd` on the VPS with **scoped** rules (not whole-disk). Suggested
`-k` keys — the Pi's "Logs" dashboard filters on exactly these:

| key          | watch (example)                                  |
|--------------|--------------------------------------------------|
| `uploads`    | your web upload dir (e.g. `-w /srv/www/uploads -p wa`) |
| `nginx_conf` | `-w /etc/nginx -p wa`                             |
| `ssh_conf`   | `-w /etc/ssh -p wa`                              |
| `ssh_keys`   | `-w /root/.ssh -p wa` (and per-user `~/.ssh`)    |
| `stack_env`  | `-w /path/to/stack/.env -p rwa`                  |

Ship `/var/log/audit/audit.log` via Alloy (it may carry old timestamps in
batches — the Pi's Loki accepts backfill, `reject_old_samples: false`). If you
use different key names, update the `audit_key` variable in the Pi dashboard
`grafana/dashboards/logs.json`.

## 5. Telegram — apply the new alert routes on the Pi (one command, needs sudo)

The Pi's Alertmanager already delivers **critical** alerts to Telegram. The
new **warning** routes (cert expiry, site down) and the SSH accepted-login
route were added to `alertmanager/alertmanager.yml.tmpl` but need a re-render:

    cd /mnt/datos/pi-tale && sudo make telegram-setup

(That substitutes the chat id and writes the bot token to the secrets file;
Alertmanager reloads it. Runs on the Pi, not the VPS.)
