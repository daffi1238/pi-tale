# Uptime Kuma

Uptime Kuma is the operator-friendly UI layer of pi-tale. It is shipped
in `compose/extras.yml` and is **optional** — the rest of pi-tale works
without it.

## Why it's here

Editing YAML in `prometheus/targets/` is fine for engineers but
intimidating for a part-time IT admin. Kuma fills that gap: a clean web
UI to add a monitor, see its history, and configure notifications, all
without touching files.

It is **not** a replacement for Prometheus/Alertmanager — it is a
parallel, independent system aimed at human-friendly monitoring. The
two systems will happily coexist; see [Tradeoffs](#tradeoffs) below.

## Bringing it up

```bash
docker compose \
  -f compose/core.yml \
  -f compose/extras.yml \
  --env-file compose/.env up -d
```

Open `http://<pi-ip>:3001` in a browser. On first visit Kuma asks you
to create the **admin user** (username + password, stored locally in
its SQLite database under `data/uptime-kuma/`). There is no default
admin and no env-var bootstrap; you create it once, then log in.

## Adding a monitor

In the UI: **"Add New Monitor"** → choose a type → fill the target →
Save. The useful types for a small network are:

| Type        | Use it for                                                 |
| ----------- | ---------------------------------------------------------- |
| **Ping**    | "Is this IP reachable?" — gateway, APs, NAS, IP cameras.   |
| **HTTP(s)** | A web service responds with a 2xx (your router admin, a NAS UI). |
| **TCP Port**| A specific port is open (SSH on 22, a custom service).     |
| **DNS**     | A domain resolves through a specific resolver.             |
| **Docker Container** | A local container is running (via the Docker socket). |

Tip: tag monitors by location and role (`hotel`, `floor-1`, `ap`,
`pos`...). Kuma supports tags natively and they're a much cleaner
filter than naming alone once you have more than ~10 monitors.

## Notifications

Kuma has its own notification system, completely independent from
Alertmanager. Settings → Notifications → "Setup Notification" lets you
add Telegram, email (SMTP), Discord, Slack, ntfy, webhook, etc. You
then attach one or more notification channels per monitor (or as a
default).

Most pi-tale operators use:

- **Telegram** for "down right now" pings (Kuma).
- **Email (SMTP)** for slower, summary-style alerts (Kuma).

If you also enable the Alertmanager receivers in
`alertmanager/alertmanager.yml`, you will have **two notification
sources** firing. That's not necessarily wrong — Kuma is excellent at
"is X up?" while Alertmanager is good at "is the metric X above
threshold Y?" — but be intentional about who alerts on what so you
don't get paged twice for the same outage.

## Tradeoffs

| Use Kuma when…                                          | Use Prometheus + Alertmanager when…                            |
| ------------------------------------------------------- | -------------------------------------------------------------- |
| You want a friendly UI for non-engineers.               | You need metric-level alerts (CPU > 90%, disk filling up).     |
| The question is binary: "is it up?".                    | The question involves rate, percentile, ratio, prediction.     |
| The operator should be able to add hosts without SSH.   | The target list is large enough that version control matters.  |
| Notifications need to be self-service.                  | Routing/grouping/inhibition is non-trivial.                    |

In practice most pi-tale deployments end up using **both**:

- Kuma for the day-to-day "is the AP up?" view that staff actually look
  at.
- Prometheus/Alertmanager for the deeper "the Pi is throttling because
  it's 78 °C" alerts the engineer cares about.

## Future: feeding Kuma into Prometheus

Kuma 1.21+ exposes a `/metrics` endpoint protected by an API key
(Settings → API Keys in the UI). When that integration lands in pi-tale
you'll just:

1. Create an API key in Kuma.
2. Paste it as `UPTIME_KUMA_API_KEY` in `compose/.env`.
3. A scrape job in `prometheus.yml` will pull Kuma's per-monitor status
   alongside the rest.

This is intentionally not wired yet — it's worth setting up only after
you have monitors in Kuma worth surfacing in Grafana.

## Backups

Kuma keeps **all its state** in a SQLite database at
`data/uptime-kuma/kuma.db`. To back it up, copy that file (the future
`scripts/backup.sh` will include it). To restore, replace the file with
the container stopped, then start it again.
