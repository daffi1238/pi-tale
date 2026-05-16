# WiFi probe

A small Python Prometheus exporter that scans the RF environment around
the Pi and publishes per-BSSID metrics. Lives in
[`exporters/wifi/`](../../exporters/wifi/) and is wired through
[`compose/probes.yml`](../../compose/probes.yml).

## Why this exists

The UniFi controller (or any other AP-side telemetry) only sees what your
own APs hear. The probe gives you a **neutral, client-side view** of the
neighbourhood: what other networks are around, on which channels, at what
signal strength — including how your own AP looks from the Pi's location.

In practice this lets you:

- Spot channel congestion before users complain about it.
- Catch your AP drifting to a noisy channel after a DFS event.
- Detect rogue / unexpected SSIDs at a glance.
- Track the long-term signal of your own networks from a fixed point.

## How it works

The exporter runs `iw dev <iface> scan` on a configurable interval (30s
by default) and parses the textual output. The interface is brought `up`
beforehand but is **not** put into monitor mode: a managed-mode unassoci‐
ated interface is enough for `iw scan`, and it stays passive — no probes
are injected, nothing is decrypted.

Per scan, every parsed BSSID becomes one sample on each of the gauges:

```
pitale_wifi_bss_signal_dbm{bssid,ssid,channel,band}
pitale_wifi_bss_frequency_mhz{bssid,ssid,channel,band}
pitale_wifi_bss_channel{bssid,ssid,channel,band}
pitale_wifi_bss_beacon_interval_tu{bssid,ssid,channel,band}
pitale_wifi_bss_last_seen_seconds{bssid,ssid,channel,band}
pitale_wifi_bss_encryption_info{bssid,ssid,channel,band,encryption}
```

Gauges are **cleared and re-populated on every scan**, so BSSIDs that
disappear drop out of `/metrics` within one cycle. Use
`pitale_wifi_scan_last_success_timestamp_seconds` to alert on a stalled
exporter (e.g. driver crash, USB unplugged).

## Hardware

Tested on the **Alfa AWUS036ACH** (Realtek RTL8812AU, USB ID `0bda:8812`).
The driver is out-of-tree; install it once with
[`bootstrap/wifi-driver-setup.sh`](../../bootstrap/wifi-driver-setup.sh)
and DKMS will keep it building across kernel upgrades.

Any USB adapter that exposes a managed-mode netdev and is supported by
`iw scan` will work; you do not strictly need a monitor-mode capable one.
The reason we recommend the AWUS036ACH is mostly mechanical: external
antennas + dual-band + Linux driver story that is well-trodden.

The probe uses a **dedicated** interface (`wlan1` by default). The Pi's
built-in `wlan0` stays free for management or fallback connectivity.

## Networking model

The exporter container runs with `network_mode: host`. The wlan netdev
only exists in the host's network namespace, so this is unavoidable.
Side effect: the listener at `${WIFI_LISTEN_PORT:-9116}` is bound on the
host's `0.0.0.0`, not inside the `pitale` docker bridge. Prometheus
(which lives on the bridge) reaches it through
`host.docker.internal:9116`, made resolvable by an `extra_hosts:
host-gateway` mapping on the Prometheus service in `compose/core.yml`.

If your Pi sits on a network you do not control, block tcp/9116 inbound
on the LAN interface — the metrics include SSIDs and BSSIDs of every
network the Pi can hear.

## SSID filtering

`WIFI_SSID_PATTERNS` is a comma-separated list of `fnmatch` globs. Only
SSIDs that match are exported; everything else is dropped at scan time
(not at scrape time), keeping Prometheus cardinality low.

```
WIFI_SSID_PATTERNS=MOVISTAR-WIFI6-C738*,vodafone317B*
```

- `*` is a shell-style wildcard. `MOVISTAR-WIFI6-C738*` matches both the
  2.4 GHz and 5 GHz radios that share the same base SSID, regardless of
  the suffix the AP appends (`-5G`, `_5G`, empty, etc.).
- An empty value disables filtering — useful for a one-off RF survey, but
  expect dozens of new series on a busy block. Switch it back as soon as
  you're done.
- Hidden SSIDs (empty string in beacons) are always dropped: there is no
  glob that would match them by accident, and they would all collapse to
  a single `ssid=""` label otherwise.

## Privacy

Set `WIFI_HASH_SSID=1` to publish `sha256:<12hex>` instead of the literal
SSID. The mapping never leaves the exporter, so dashboards built on the
hash will keep working as long as the SSID itself doesn't change. BSSIDs
(MAC addresses) are always exported as-is — they are needed to
disambiguate same-SSID radios from each other.

## Troubleshooting

```bash
# Driver loaded? The module is 8812au (not rtl8812au).
lsmod | grep 8812au

# Interface visible?
iw dev

# Manual scan (run as root):
sudo iw dev wlan1 scan | less

# Container logs:
docker logs -f pitale-wifi-exporter

# Scrape from Prometheus' point of view:
docker exec pitale-prometheus wget -qO- http://host.docker.internal:9116/metrics | head
```

Common failure modes:

- **`Operation not permitted`** in the logs → the container is missing
  `NET_ADMIN`/`NET_RAW`. Both caps must be in `cap_add` and the container
  must run as root (the default).
- **`Network is down`** → `ip link set wlan1 up` failed. Usually means
  the adapter is unplugged or the driver did not load. Re-run
  `bootstrap/wifi-driver-setup.sh`.
- **Empty matched count but non-zero `scan_bss_count`** → your SSID
  patterns don't match what the AP actually advertises. Temporarily unset
  `WIFI_SSID_PATTERNS` and grep the literal SSIDs from a raw scan.
