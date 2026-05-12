# Architecture

pi-tale runs every moving piece in a Docker container on a single
Raspberry Pi, with persistent data on an SSD. The repo is organised in
**compose layers**: a small core that always runs, plus optional layers
you stack on top with `-f`.

## Layout

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

## Compose layers

| File                  | Contents                                              | When to add it                                  |
| --------------------- | ----------------------------------------------------- | ----------------------------------------------- |
| `compose/core.yml`    | Prometheus, Alertmanager, Grafana, Loki, Promtail, node_exporter, blackbox_exporter, cAdvisor | Always.                                         |
| `compose/unifi.yml`   | UniFi Network Application + unifi-poller              | When monitoring a UniFi-based network.          |
| `compose/probes.yml`  | snmp_exporter, custom WiFi probe                      | When you have SNMP devices or an Alfa adapter.  |
| `compose/extras.yml`  | Uptime Kuma and other operator-friendly extras        | When you want a friendlier "is X up?" panel.    |

Stack them with `-f`:

```bash
docker compose \
  -f compose/core.yml \
  -f compose/unifi.yml \
  -f compose/probes.yml \
  --env-file compose/.env up -d
```

## Data flow

1. **Metrics.** Every exporter exposes a `/metrics` endpoint inside the
   `pitale` Docker network. Prometheus scrapes them on a 30 s interval
   and stores the result as a local TSDB under `data/prometheus/`.
2. **Probes.** `blackbox_exporter` is configured as a *delegate*: a
   Prometheus job pushes the actual target through the `target` URL
   parameter (see `prometheus/prometheus.yml`). New probe targets are
   added by dropping YAML into `prometheus/targets/`.
3. **Logs.** Promtail reads host syslog plus the JSON logs of every
   Docker container and ships them to Loki over HTTP. Loki stores chunks
   under `data/loki/`.
4. **Alerts.** Prometheus evaluates rules from `prometheus/rules/*.yml`
   and forwards firing alerts to Alertmanager. Alertmanager applies the
   routing tree in `alertmanager/alertmanager.yml` and dispatches to the
   configured receivers (Telegram / SMTP — both off by default).
5. **Dashboards.** Grafana is provisioned with three datasources
   (Prometheus, Loki, Alertmanager) and reads dashboards from
   `grafana/dashboards/`.

## Storage layout

```
/mnt/datos/                      ← SSD mountpoint (production)
└── pi-tale/
    ├── data/
    │   ├── prometheus/          # TSDB
    │   ├── alertmanager/        # state
    │   ├── grafana/             # SQLite, plugins
    │   ├── loki/                # chunks + tsdb index
    │   └── promtail/            # positions file
    └── backup/                  # rotated snapshots from scripts/backup.sh
```

For local development the same tree lives under `./data/` next to the
compose files; that is what `compose/core.yml` mounts by default.

## What goes where

| Concern                  | Lives in                                        |
| ------------------------ | ----------------------------------------------- |
| Scrape configuration     | `prometheus/prometheus.yml`                     |
| Probe targets            | `prometheus/targets/blackbox-*.yml`             |
| Alert rules              | `prometheus/rules/*.yml`                        |
| Alert routing            | `alertmanager/alertmanager.yml`                 |
| Grafana datasources      | `grafana/provisioning/datasources/`             |
| Grafana dashboards       | `grafana/dashboards/` (JSON)                    |
| Loki tuning              | `loki/loki-config.yml`                          |
| Log collection           | `promtail/promtail-config.yml`                  |
| Blackbox modules         | `blackbox/blackbox.yml`                         |
| Secrets / host overrides | `compose/.env` (git-ignored)                    |

## Out of scope

- Multi-node clustering (one Pi, one stack — by design).
- Long-term metrics archiving (Thanos, Mimir, etc.).
- Remote write to a cloud Prometheus.

If you outgrow a single Pi, pi-tale is the wrong tool for the job.
