# Changelog

All notable changes to **pi-tale** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `scripts/backup.sh`: working implementation. Stops the running
  pi-tale compose projects (`pi-tale-core`, `pi-tale-probes`,
  `pi-tale-extras`) to take a self-consistent snapshot, then tars
  `data/<service>` into `backup/pi-tale-backup-<UTC-timestamp>.tar.gz`
  with `--numeric-owner` so uids 65534/472/10001 survive a restore
  on another host. Rotates to the `BACKUP_KEEP` newest archives
  (default 7), restarts only the stacks it stopped (also on failure,
  via `trap`). Flags: `--live` (don't stop containers, fast and
  best-effort), `--include-env` (also archive `compose/.env` — opt-in
  because it carries secrets), `--dest <path>` (override destination).
- `scripts/restore.sh`: companion that validates the archive shape,
  stops the running stacks, moves the current `data/` aside as
  `data.bak-<timestamp>` (kept, not deleted), extracts and restarts.
  Refuses to run without root because archived uids cannot otherwise
  be restored. Confirmation prompt unless `--yes`.
- `.github/workflows/ci.yml`: first CI pipeline. Parallel jobs for
  `shellcheck` over `bootstrap/*.sh` and `scripts/*.sh`,
  `promtool check config` + `check rules` for
  `prometheus/prometheus.yml` and `prometheus/rules/*.yml`,
  `amtool check-config` for `alertmanager/alertmanager.yml`, and
  `docker compose config -q` over every compose file (standalone)
  plus the documented stacked combinations (`core + extras`,
  `core + unifi`). promtool/amtool run from the exact image tags
  pinned in `compose/core.yml`, so CI validates what production
  actually loads.

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

- `bootstrap/wifi-driver-setup.sh`: idempotent installer for the
  Realtek RTL8812AU USB WiFi driver (chipset `0bda:8812`, e.g. Alfa
  AWUS036ACH). Builds the out-of-tree `morrownr/8812au-20210820`
  source via DKMS (pinned to commit `dabcb74`, the last revision that
  compiles on kernel 6.12 — later commits reference an undefined
  `_FW_UNDER_SURVEY` symbol). Re-runs cleanly: it removes stale DKMS
  registrations and legacy source dirs before retrying.

- `exporters/wifi/`: first working release of the WiFi RF probe.
  Python exporter that runs `iw dev <iface> scan` on a 30s interval
  (configurable), parses the textual output into per-BSSID samples,
  and exposes them at `:9116/metrics`. Filtering happens at the
  exporter (`WIFI_SSID_PATTERNS`, comma-separated `fnmatch` globs;
  default `MOVISTAR-WIFI6-C738*,vodafone317B*`) so Prometheus
  cardinality stays bounded. Optional `WIFI_HASH_SSID=1` swaps SSIDs
  for `sha256[:12]` if a dashboard must be sharable. Gauges are
  cleared and re-published on every scan, so vanished BSSIDs drop
  out within one cycle.
- `compose/probes.yml`: wires the exporter into the stack with
  `network_mode: host` and `cap_add: [NET_ADMIN, NET_RAW]` (required
  to see and drive the wlan netdev).
- `compose/core.yml`: Prometheus gets an
  `extra_hosts: host.docker.internal:host-gateway` mapping so it can
  scrape the exporter through the host network namespace.
- `prometheus/prometheus.yml`: new `wifi_exporter` scrape job
  targeting `host.docker.internal:9116`.
- `compose/.env.example`: `WIFI_IFACE`, `WIFI_SCAN_INTERVAL`,
  `WIFI_SCAN_TIMEOUT`, `WIFI_SSID_PATTERNS`, `WIFI_HASH_SSID`,
  `WIFI_LISTEN_PORT`.
- `prometheus/targets/blackbox-http-public-web.yml`: first real HTTP
  liveness targets — `hostalcamponuevo.es`, `devsec.es`,
  `www.twin-tongues.com`. Probed via per-site blackbox modules so
  we get TLS validation, follow-redirects, status code, per-phase
  timing, cert-expiry timestamp AND a body regex that asserts the
  homepage `<title>` is still being served. Catches the "200 OK but
  the WAF / hosting panel is serving an error page" failure mode
  that pure ICMP and a generic http_2xx would miss. Labelled
  `kind=extranet, owner=self`.
- `blackbox/blackbox.yml`: three new modules
  `http_2xx_title_hostalcamponuevo`, `http_2xx_title_devsec`,
  `http_2xx_title_twin_tongues` — each is `http_2xx` plus
  `fail_if_body_not_matches_regexp` for the expected title, with
  `fail_if_not_ssl: true` for good measure.
- `prometheus/prometheus.yml`: the `blackbox_http` job now reads an
  optional `module` label from each target group and rewrites it
  into `__param_module` via relabel (`regex: (.+)` keeps the default
  `http_2xx` when the label is absent). This is what lets the new
  per-site modules coexist with the generic check in the same scrape
  job.

- `grafana/dashboards/wifi-probe.json`: provisioned dashboard
  "WiFi Probe" (uid `pitale-wifi-probe`). Stats row (tracked SSIDs,
  matched BSSIDs, BSSIDs in air, last scan age with thresholds),
  full-width per-BSSID signal timeseries with mean/max/min/last in
  the legend, scan-health timeseries (duration / counts / error rate)
  and current-snapshot table sorted by signal. Template variables
  `ssid` and `band` are auto-populated from the metric labels.

### Changed
- Grafana datasource provisioning now sets explicit UIDs
  (`pitale-prometheus`, `pitale-loki`, `pitale-alertmanager`) so
  committed dashboards can reference them deterministically.

[Unreleased]: https://github.com/daffi1238/pi-tale/compare/HEAD...HEAD
