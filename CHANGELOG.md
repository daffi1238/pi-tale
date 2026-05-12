# Changelog

All notable changes to **pi-tale** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial repository skeleton (directories for `compose/`, `bootstrap/`,
  `prometheus/`, `alertmanager/`, `grafana/`, `exporters/wifi/`,
  `examples/`, `scripts/`, `docs/`).
- Root meta files: `README.md`, `LICENSE` (Apache 2.0), `CONTRIBUTING.md`,
  `.gitignore`, `.editorconfig`.
- `compose/core.yml` with Prometheus, Grafana, Loki, Promtail,
  Alertmanager, node_exporter, blackbox_exporter and cAdvisor.
- `compose/.env.example` documenting every environment variable.
- Baseline `prometheus/prometheus.yml`, alert rules placeholder, and
  `prometheus/targets/` for file-based service discovery.
- `alertmanager/alertmanager.yml` with Telegram and SMTP receivers
  (both commented by default).
- Grafana datasource provisioning for Prometheus and Loki.
- `bootstrap/install.sh` (Pi detection, Docker install, SSD check,
  `.env` bootstrap), plus skeletons for `ssd-setup.sh`,
  `system-tune.sh`, `docker-setup.sh`.
- Initial `docs/architecture.md`, `docs/installation.md`,
  `docs/hardware.md` and per-target stubs.
- `compose/extras.yml` now ships **Uptime Kuma**
  (`louislam/uptime-kuma:1.23.16-debian`) on port 3001 — friendly UI to
  add ping / HTTP / TCP / DNS monitors and manage their notifications
  without editing YAML. Independent from Prometheus/Alertmanager (see
  `docs/targets/uptime-kuma.md` for the tradeoffs).
- `bootstrap/install.sh` now prepares `data/uptime-kuma/` so enabling
  the extras layer needs no extra setup.
- `compose/.env.example` carries `UPTIME_KUMA_PORT` and a placeholder
  for the future `UPTIME_KUMA_API_KEY` (Prometheus integration not
  wired yet).
- `prometheus/targets/blackbox-icmp-lan.yml`: first real ICMP liveness
  targets for the local network (`192.168.1.1`, `192.168.1.2`,
  `192.168.0.1`, and the `10.10.10.10–50` infra range), grouped by
  subnet via labels.
- `grafana/dashboards/icmp-probes.json`: provisioned dashboard "ICMP
  Probes" (uid `pitale-icmp-probes`) — UP/DOWN counters, state-timeline
  per target, RTT per target and a current-status table, with
  `instance`/`subnet` template variables.

### Changed
- Grafana datasource provisioning now sets explicit UIDs
  (`pitale-prometheus`, `pitale-loki`, `pitale-alertmanager`) so
  committed dashboards can reference them deterministically.

[Unreleased]: https://github.com/daffi1238/pi-tale/compare/HEAD...HEAD
