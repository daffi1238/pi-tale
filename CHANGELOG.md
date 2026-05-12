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

[Unreleased]: https://github.com/daffi1238/pi-tale/compare/HEAD...HEAD
