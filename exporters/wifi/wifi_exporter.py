"""pi-tale — WiFi RF exporter (skeleton).

Not implemented yet. The real version will:

  1. Bring an external monitor-mode-capable WiFi adapter (Alfa
     AWUS036ACM or similar) into monitor mode.
  2. Run `iw dev <iface> scan` on a configurable interval.
  3. Parse the output into per-BSSID samples.
  4. Expose them on :9116/metrics for Prometheus.

See docs/targets/wifi-probe.md for design notes.
"""

from __future__ import annotations


def main() -> None:
    raise SystemExit(
        "wifi_exporter is not implemented yet. "
        "Track progress in docs/targets/wifi-probe.md."
    )


if __name__ == "__main__":
    main()
