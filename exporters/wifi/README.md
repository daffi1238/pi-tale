# wifi_exporter — pi-tale RF probe

A small Python Prometheus exporter that parses `iw dev <iface> scan`
output and exposes per-BSSID metrics on `:9116/metrics`.

The exporter does **not** put the radio into monitor mode. A managed-mode
interface that is `up` but unassociated is enough for `iw scan` to
enumerate every nearby BSSID. That keeps the probe passive and lets the
same adapter still be usable for other things in a pinch.

See [`docs/targets/wifi-probe.md`](../../docs/targets/wifi-probe.md) for
the design rationale and hardware notes.

## Configuration

| Env var               | Default                                 | Meaning                                              |
| --------------------- | --------------------------------------- | ---------------------------------------------------- |
| `WIFI_IFACE`          | `wlan1`                                 | interface to scan                                    |
| `WIFI_SCAN_INTERVAL`  | `30`                                    | seconds between scans                                |
| `WIFI_SCAN_TIMEOUT`   | `20`                                    | hard timeout for a single `iw scan`                  |
| `WIFI_SSID_PATTERNS`  | `MOVISTAR-WIFI6-C738*,vodafone317B*`    | comma-separated `fnmatch` globs; empty = export all  |
| `WIFI_LISTEN_HOST`    | `0.0.0.0`                               | bind address                                         |
| `WIFI_LISTEN_PORT`    | `9116`                                  | metrics port                                         |
| `WIFI_HASH_SSID`      | `0`                                     | if truthy, export `sha256:<12hex>` instead of SSID   |

## Metrics

```
pitale_wifi_bss_signal_dbm{bssid,ssid,channel,band}            -54
pitale_wifi_bss_frequency_mhz{bssid,ssid,channel,band}         5180
pitale_wifi_bss_channel{bssid,ssid,channel,band}               36
pitale_wifi_bss_beacon_interval_tu{bssid,ssid,channel,band}    100
pitale_wifi_bss_last_seen_seconds{bssid,ssid,channel,band}     2.4
pitale_wifi_bss_encryption_info{bssid,ssid,channel,band,encryption}  1

pitale_wifi_scan_duration_seconds                              3.1
pitale_wifi_scan_last_success_timestamp_seconds                1.71e9
pitale_wifi_scan_bss_count                                     27
pitale_wifi_scan_matched_count                                 6
pitale_wifi_scan_errors_total                                  0
```

The per-BSSID gauges are **fully cleared and re-published on every scan**
so BSSIDs that disappear from the air drop out of `/metrics` within one
cycle instead of lingering at their last value.

## Running standalone (without compose)

```bash
docker build -t pi-tale-wifi-exporter .
docker run --rm --network host \
  --cap-add NET_ADMIN --cap-add NET_RAW \
  -e WIFI_IFACE=wlan1 \
  -e WIFI_SCAN_INTERVAL=30 \
  -e WIFI_SSID_PATTERNS='MOVISTAR-WIFI6-C738*,vodafone317B*' \
  pi-tale-wifi-exporter
```

Inside the pi-tale stack the service is defined in
[`compose/probes.yml`](../../compose/probes.yml) and scraped from
Prometheus via `host.docker.internal:9116`.
