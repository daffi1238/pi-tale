# wifi_exporter — pi-tale RF probe

A small Python Prometheus exporter that parses `iw dev <iface> scan`
output and exposes per-BSSID metrics.

> Status: skeleton. The exporter is not implemented yet — see
> [`docs/targets/wifi-probe.md`](../../docs/targets/wifi-probe.md) for
> the planned behaviour and hardware requirements.

## Planned metrics

```
# HELP wifi_signal_dbm Signal level of a seen BSSID, in dBm.
# TYPE wifi_signal_dbm gauge
wifi_signal_dbm{bssid="aa:bb:cc:dd:ee:ff",ssid="my-network",channel="36",band="5"} -54

# HELP wifi_seen_total Number of times a BSSID has been seen.
# TYPE wifi_seen_total counter
wifi_seen_total{bssid="aa:bb:cc:dd:ee:ff"} 42
```

## Running locally (target shape)

```bash
docker build -t pi-tale-wifi-exporter .
docker run --rm --net=host --cap-add NET_ADMIN --cap-add NET_RAW \
  -e WIFI_IFACE=wlan1 -e WIFI_INTERVAL=30 \
  pi-tale-wifi-exporter
```

The exporter listens on `:9116/metrics` (port subject to change before
v0.1).
