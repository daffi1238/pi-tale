# Changelog

All notable changes to **pi-tale** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Containerised dashboards for node_exporter and cAdvisor**
  (`grafana/dashboards/{node-exporter,cadvisor}.json`). Built from
  scratch using the existing pi-tale colour/threshold conventions so
  cold-boot works offline — no more importing dashboard #1860 from
  grafana.com on first launch. The cAdvisor dashboard ships a `name`
  template variable for filtering and a snapshot table sorted by
  container name.
- **Two alerts and five recording rules.**
  `prometheus/rules/observability.yml` gains
  `PrometheusTSDBCompactionFailing` (critical, fires on any increase in
  `prometheus_tsdb_compactions_failed_total` over 1h — compaction
  failures do not self-heal) and `LokiIngestionErrors` (warning, fires
  on sustained 5xx on `.*push.*` routes).
  `prometheus/rules/recording.yml` (new) pre-aggregates the
  Pi's expensive panels: `instance:probe_duration_seconds:p99_5m`,
  `instance:probe_success:ratio_1h`,
  `bssid_ssid:pitale_wifi_bss_signal_dbm:avg5m` and friends.
- **Optional TLS terminator** (`compose/tls.yml` + `caddy/Caddyfile`).
  Caddy 2.8 in front of Grafana with auto-issued certs — Let's Encrypt
  if `TLS_HOSTNAME` is a real domain, internal CA otherwise. Brought
  up via `make tls`; combine with `BIND_HOST=127.0.0.1` to make HTTPS
  the only path in. Blocks `/metrics`, `/admin/*` and `/debug/*` from
  the public route while leaving the internal Prometheus scrape on
  `grafana:3000` untouched.

### Changed
- **Secrets via `*_FILE` for Grafana admin + SMTP.** Compose no longer
  carries `GF_SECURITY_ADMIN_PASSWORD` in plain env — Grafana reads it
  from `/etc/grafana/secrets/admin_password` (bind-mounted from
  `data/grafana/secrets/`) via its native
  `GF_SECURITY_ADMIN_PASSWORD__FILE`. Same shape now documented for
  SMTP in the alertmanager template. `scripts/secrets-setup.sh` (new,
  shellcheck-clean) reads `GRAFANA_ADMIN_PASSWORD` and `SMTP_PASSWORD`
  from `compose/.env` and writes both files with the right uid +
  inode-preserving overwrite. `make secrets-setup` wraps it via sudo.
  **Migration:** existing installs MUST run `sudo make secrets-setup`
  once before `make up` or Grafana will fail to start.
- **cAdvisor no longer runs `privileged: true`.** Replaced with the
  three caps cAdvisor actually needs on Raspberry Pi OS bookworm
  (cgroupsv2, no AppArmor enforcement by default): `SYS_ADMIN`,
  `SYS_PTRACE`, `DAC_READ_SEARCH`. `/dev/kmsg` is still passed
  explicitly. Significantly reduces blast radius (privileged grants
  ALL caps and lifts seccomp).
- **wifi_exporter listener off the LAN.** The `pitale` bridge now has
  a static IPAM block (172.31.0.0/24, gateway 172.31.0.1). The
  `network_mode: host` exporter binds on that gateway IP by default
  instead of 0.0.0.0, so the metrics endpoint is only reachable from
  the docker bridge — not from any LAN host. Prometheus inside the
  bridge keeps reaching it via `host.docker.internal:9116`.
- **CI tracks the post-baseline layout.** `amtool` validates the
  rendered template (the committed source is `alertmanager.yml.tmpl`),
  the compose job validates `wireguard.yml` and `tls.yml` standalone,
  and the misleading "stacked compose" combinations are removed since
  each YAML now declares its own `name:` and is brought up via
  separate `make <stack>` targets.

- **WireGuard moved from the host to a dedicated container** for blast
  radius isolation. With the previous host-mode tunnel a compromised
  VPS could reach any service the Pi exposed on `0.0.0.0` (sshd,
  Grafana, Prometheus UI, ...) via `10.50.0.1`. With the gateway
  container, only the gateway is reachable at that address, and only
  the two narrow forwarding paths it advertises are open: outbound
  Prometheus → VPS exporters on tcp/{9100,9080,9113,9187}, inbound
  VPS Promtail → Loki on tcp/3100. Everything else is silently dropped.
  - `wireguard/` (new): `Dockerfile`, `entrypoint.sh`, `wg0.conf.tmpl`.
    The entrypoint resolves Loki via Docker DNS at startup, brings up
    wg0 via `wg-quick`, and installs the two DNAT + MASQUERADE paths
    using kernel iptables.
  - `compose/wireguard.yml` (new): separate compose project
    `pi-tale-wireguard`. Hosts `wireguard_gateway` (NET_ADMIN,
    `/dev/net/tun`, sysctl `ip_forward=1`) and `wireguard_exporter`
    sharing the gateway's netns (`network_mode:
    service:wireguard_gateway`) so it can see wg0. Healthcheck: wg0
    handshake within the last 5 min.
  - `bootstrap/wireguard-setup.sh` rewritten. No longer touches
    `/etc/wireguard/` on the host. Keys live in
    `data/wireguard/keys/` and the rendered `wg0.conf.in` in
    `data/wireguard/runtime/` (both gitignored, 0600 root). Refuses
    to run if `wg-quick@wg0` is still enabled on the host (would
    dual-bind UDP/51820). Phase 2 also (re)starts the gateway
    container and verifies the handshake from inside it.
  - `compose/probes.yml`: `wireguard_exporter` removed (moved to
    `compose/wireguard.yml`).
  - `prometheus/prometheus.yml`: `wireguard_exporter` target moves
    from `host.docker.internal:9586` to `wireguard_gateway:9586`.
  - `prometheus/targets/vps-*-main.yml`: targets change from
    `10.50.0.2:<port>` to `wireguard_gateway:<port>`. Prometheus
    scrapes the gateway; the gateway DNATs to the VPS.
  - `Makefile`: new `wireguard`, `wireguard-down`. `wireguard-status`
    now `docker exec`s into the gateway (no host wg required).
  - `bootstrap/install.sh`: pre-creates `data/wireguard/{keys,runtime}`
    with root ownership.

### Added
- **Defense-in-depth port binding** via the new `BIND_HOST` env var.
  All UIs/exporter ports published on the host (Grafana, Prometheus,
  Alertmanager, Loki, cAdvisor, Uptime Kuma) now bind on
  `${BIND_HOST:-0.0.0.0}`. Operators on untrusted LANs can set
  `BIND_HOST=127.0.0.1` and access the UIs only through SSH tunnels
  (`ssh -L 3000:localhost:3000 pi`). Documented in `compose/.env.example`.

- **VPS monitoring over a WireGuard overlay.** End-to-end skeleton for
  scraping a remote VPS from the Pi without exposing any exporter to
  the public internet.
  - `bootstrap/wireguard-setup.sh`: idempotent two-phase setup. Phase 1
    generates the Pi's keypair, writes a partial `wg0.conf`, and prints
    the snippet to run on the VPS (which installs WG, generates its
    own keypair, registers the Pi as a peer, opens UDP/51820, and
    prints its public key). Phase 2 (after `VPS_WG_PUBKEY` is set in
    `compose/.env`) finalises the peer block and verifies the
    handshake. Sub-30s end-to-end on a happy path.
  - `exporters/wireguard/`: first-party Python exporter (matches the
    wifi_exporter pattern). Reads `wg show all dump` on a 30s interval
    and exposes `wireguard_latest_handshake_seconds`,
    `wireguard_sent_bytes_total`, `wireguard_received_bytes_total`,
    `wireguard_peers_count` and friends on `:9586/metrics`. Same
    metric names as the (now-removed) upstream image so committed
    rules and dashboards keep working.
  - `compose/probes.yml`: new `wireguard_exporter` service with
    `network_mode: host` and `cap_add: [NET_ADMIN]`. Builds locally
    (no Docker Hub dependency).
  - `prometheus/prometheus.yml`: five new scrape jobs —
    `wireguard_exporter` (host.docker.internal:9586) plus
    `vps_node`, `vps_cadvisor`, `vps_nginx`, `vps_postgres` via
    `file_sd` over `prometheus/targets/vps-*-*.yml`.
  - `prometheus/targets/vps-{node,cadvisor,nginx,postgres}-main.yml`:
    starter target files pointing at `10.50.0.2:<port>` with
    `host=vps` label.
  - `prometheus/rules/vps.yml`: 12 alerts across host, containers,
    nginx, postgres and the tunnel itself. `WireguardTunnelDown`
    (no handshake in 5m), `VpsNodeDown`, `VpsDiskFillingUp`,
    `PostgresDown`, `VpsContainerOOMKilled` etc. — the critical ones
    route to Telegram automatically (existing route by `severity`).
  - `grafana/dashboards/wireguard.json`: tunnel state, handshake
    freshness, tx/rx throughput (6 panels).
  - `grafana/dashboards/vps-host.json`: stats row + CPU by mode,
    memory, network throughput, per-mountpoint FS usage (9 panels).
    Template var `host` so multiple VPSes are a relabeling away.
  - `compose/.env.example`: new `VPS_PUBLIC_IP`, `VPS_WG_PUBKEY`,
    `WG_PORT`, `WG_PI_IP`, `WG_VPS_IP`, `WG_NETWORK`,
    `WIREGUARD_LISTEN_PORT`.
  - `Makefile`: `wireguard-setup`, `wireguard-status`.
  - `examples/vps-monitoring/`: ready-to-deploy compose project for
    the VPS side — `node_exporter`, `cAdvisor`, `nginx_exporter`
    (with the matching `stub_status` snippet), `postgres_exporter`,
    `promtail` pushing logs to Loki on the Pi over WG. All exporter
    listeners bind on the WG overlay only. `README.md` walks
    through each step including the `pg_monitor` SQL.
- **Telegram alerts wired end-to-end.** Alertmanager now ships an
  active `telegram` receiver and the route `severity=critical → telegram`
  (repeat 1h). Both per-install values (`TELEGRAM_BOT_TOKEN` and
  `TELEGRAM_CHAT_ID`) live in `compose/.env`; nothing personal ever
  enters a committed file.
- `alertmanager/alertmanager.yml.tmpl` (committed) is the source of
  truth for alertmanager config. The runtime file lives in
  `data/alertmanager/runtime/alertmanager.yml` (gitignored) and is
  rendered from the template by `make telegram-setup`, substituting
  the `__TELEGRAM_CHAT_ID__` placeholder. The bot token is written
  in parallel to `data/alertmanager/secrets/telegram_bot_token` and
  loaded by alertmanager via its native `bot_token_file` directive.
- `scripts/telegram-setup.sh`: idempotent installer. Reads
  `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` from `compose/.env`
  (or accepts both as positional arguments), validates shapes
  (token = `<digits>:<base64-ish>`, chat id = non-zero integer with
  optional leading `-`), writes both files DIRECTLY (preserving inode
  so Docker's single-file bind mount keeps tracking the same content)
  with 0600 / 0640 perms owned by uid 65534, and POSTs `/-/reload`
  to alertmanager. Requires root because the target directories
  belong to the alertmanager uid.
- `Makefile`: `make telegram-setup [TOKEN=...]` wraps the script via
  `sudo`; `make reload-alertmanager` POSTs `/-/reload` (same shape as
  `reload-prometheus`).
- `bootstrap/install.sh`: pre-creates `data/alertmanager/secrets/`
  with the right ownership so a fresh install doesn't need a manual
  step before `make telegram-setup`.
- `compose/core.yml`: Alertmanager mounts
  `../data/alertmanager/secrets:/etc/alertmanager/secrets:ro`.
- `prometheus/rules/observability.yml`: 6 new rules covering the
  failure modes the existing `host.yml` did not. **Critical**
  (Telegram-routed): `ContainerOOMKilled`. **Warning** (visible in
  AM UI, silent unless you change the route): `BlackboxCertExpiringSoon`
  (< 14 days, guarded against `probe_ssl_earliest_cert_expiry == 0`),
  `HTTPBodyRegexMismatch` (the per-site `http_2xx_title_*` regex
  stopped matching), `ContainerRestartLoop` (>3 restarts in 15m),
  `WifiExporterStale` (no successful scan in 5m), `WifiExporterDown`
  (the exporter container itself is unreachable).
- `Makefile` at the repo root with operational shortcuts: `make up`,
  `make probes`, `make extras`, `make unifi`, `make all`, `make down`,
  `make restart`, `make ps`, `make logs [SERVICE=x]`, `make pull`,
  `make build`, `make config`, `make reload-prometheus`,
  `make reload-blackbox`, `make backup [FLAGS=...]`,
  `make restore ARCHIVE=...`. Self-documenting (`make help` lists
  every target with its tagline). Each target drives ONE compose
  project to match how the YAMLs are written (each file has its own
  `name:` — stacking with `-f` collides on container names).
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
- `README.md`, `compose/extras.yml`, `compose/unifi.yml`: replaced
  the "stack with `-f core.yml -f extras.yml`" examples with the
  separate-project pattern (`make extras` / `make unifi` etc.).
  Stacking was advertised in earlier comments but never actually
  worked because each compose file declares its own `name:` and
  merging them caused container-name collisions on the second stack.
  Deep-link docs (`docs/installation.md`, `docs/troubleshooting.md`,
  `docs/architecture.md`, `docs/targets/uptime-kuma.md`) still use
  raw compose commands and will be updated incrementally.

[Unreleased]: https://github.com/daffi1238/pi-tale/compare/HEAD...HEAD
