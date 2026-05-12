# WiFi probe

Status: stub. Lives in `exporters/wifi/`, shipped via `compose/probes.yml`.

The probe is a small Python service that:

1. Puts an external WiFi adapter (Alfa AWUS036ACM or AWUS036NHA) into
   monitor mode.
2. Runs `iw dev <iface> scan` on a configurable interval.
3. Parses the output and exposes Prometheus metrics about every BSSID
   it sees:
   - signal level
   - frequency / channel
   - SSID (optionally hashed)
   - encryption flavour
   - beacon interval

Why this exists: the UniFi controller only sees what your own APs see.
The probe gives you a *neutral* view of the RF environment — including
neighbouring networks, rogues and your own coverage from a client's
perspective.

Hardware: any cheap monitor-mode-capable USB WiFi adapter works; we test
with the two Alfa models above because their `rt2800usb` / `mt7610u`
drivers are reliable on Bookworm.
