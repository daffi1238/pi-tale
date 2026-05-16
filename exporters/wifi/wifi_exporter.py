"""pi-tale — WiFi RF exporter.

Scans the RF environment with ``iw dev <iface> scan`` on a fixed interval and
exposes per-BSSID metrics for Prometheus on ``:9116/metrics``.

The exporter does **not** put the radio into monitor mode — a plain ``iw
scan`` on a managed-mode interface that is brought ``up`` but not associated
to any network is enough to enumerate every nearby BSSID. That is what we
want here: a passive, non-disruptive client-side view of the neighbourhood,
not a packet capture.

Configuration (env vars):

  WIFI_IFACE             interface to scan (default: wlan1)
  WIFI_SCAN_INTERVAL     seconds between scans (default: 30)
  WIFI_SCAN_TIMEOUT      max seconds a single ``iw scan`` may take (default: 20)
  WIFI_SSID_PATTERNS     comma-separated glob patterns; only matching SSIDs
                         are exported. Empty = export everything.
                         (default: "MOVISTAR-WIFI6-C738*,vodafone317B*")
  WIFI_LISTEN_HOST       bind address for the metrics HTTP server (default: 0.0.0.0)
  WIFI_LISTEN_PORT       metrics port (default: 9116)
  WIFI_HASH_SSID         if "1" / "true", export sha256[:12] of the SSID
                         instead of the literal string. The original SSID
                         never leaves the process. (default: 0)

Required runtime capabilities:

  * ``NET_ADMIN`` — bring the interface up and trigger a scan.
  * ``NET_RAW``   — read scan results from the kernel.
  * ``network_mode: host`` in compose — the wlan netdev only exists in the
    host's network namespace.
"""

from __future__ import annotations

import fnmatch
import hashlib
import logging
import os
import re
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from typing import Iterable

from prometheus_client import (
    CollectorRegistry,
    Counter,
    Gauge,
    start_http_server,
)


LOG = logging.getLogger("wifi_exporter")


# --- Configuration --------------------------------------------------------

def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        LOG.warning("invalid int for %s=%r, using default %d", name, raw, default)
        return default


def _env_bool(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name, "").strip().lower()
    if not raw:
        return default
    return raw in ("1", "true", "yes", "on")


def _env_list(name: str, default: str) -> list[str]:
    raw = os.environ.get(name, default)
    return [p.strip() for p in raw.split(",") if p.strip()]


@dataclass(frozen=True)
class Config:
    iface: str = os.environ.get("WIFI_IFACE", "wlan1").strip() or "wlan1"
    scan_interval: int = _env_int("WIFI_SCAN_INTERVAL", 30)
    scan_timeout: int = _env_int("WIFI_SCAN_TIMEOUT", 20)
    listen_host: str = os.environ.get("WIFI_LISTEN_HOST", "0.0.0.0").strip() or "0.0.0.0"
    listen_port: int = _env_int("WIFI_LISTEN_PORT", 9116)
    hash_ssid: bool = _env_bool("WIFI_HASH_SSID", False)
    ssid_patterns: list[str] = field(
        default_factory=lambda: _env_list(
            "WIFI_SSID_PATTERNS",
            "MOVISTAR-WIFI6-C738*,vodafone317B*",
        )
    )


# --- Scan result model ----------------------------------------------------

@dataclass
class BSS:
    bssid: str
    ssid: str
    freq_mhz: int
    signal_dbm: float
    channel: int | None = None
    band: str | None = None        # "2.4GHz" / "5GHz" / "6GHz"
    encryption: str = "open"       # "open" | "wep" | "wpa" | "wpa2" | "wpa3" | "wpa2/wpa3"
    beacon_interval_tu: int | None = None
    last_seen_ms: int | None = None


# --- Parsing --------------------------------------------------------------

_BSS_HEADER_RE = re.compile(r"^BSS\s+([0-9a-f:]{17})", re.IGNORECASE)
_KV_RE = re.compile(r"^\s*([^:]+):\s*(.*)$")


def _band_for(freq_mhz: int) -> str | None:
    if 2400 <= freq_mhz <= 2500:
        return "2.4GHz"
    if 4900 <= freq_mhz <= 5900:
        return "5GHz"
    if 5925 <= freq_mhz <= 7125:
        return "6GHz"
    return None


def _channel_for(freq_mhz: int) -> int | None:
    # Standard channel-to-frequency map. Covers 2.4GHz (1–14) and 5GHz.
    if 2412 <= freq_mhz <= 2472:
        return (freq_mhz - 2407) // 5
    if freq_mhz == 2484:
        return 14
    if 5000 <= freq_mhz <= 5900:
        return (freq_mhz - 5000) // 5
    if 5950 <= freq_mhz <= 7125:
        # 6GHz (Wi-Fi 6E): channel N has center 5950 + 5*N MHz,
        # so channel 1 = 5955, channel 2 = 5960, etc.
        return (freq_mhz - 5950) // 5
    return None


def parse_iw_scan(output: str) -> list[BSS]:
    """Parse the textual output of ``iw dev <iface> scan``.

    iw's output is line-oriented and looks like::

        BSS aa:bb:cc:dd:ee:ff(on wlan1)
            freq: 5180
            beacon interval: 100 TUs
            signal: -67.00 dBm
            last seen: 2400 ms ago
            SSID: my-network
            RSN: ...
            WPA: ...

    There is no documented machine-readable format, but the schema above has
    been stable across iw releases for years.
    """
    bsss: list[BSS] = []
    current: BSS | None = None
    has_wpa = False
    has_rsn = False
    rsn_akm: list[str] = []

    def finalize(b: BSS) -> None:
        # Encryption: derive from the (WPA/RSN) information elements we saw.
        if has_rsn:
            # AKM "SAE" means WPA3. If both SAE and PSK are present, it is a
            # transition network. Without RSN it can never be WPA3.
            akm = " ".join(rsn_akm).upper()
            if "SAE" in akm and "PSK" in akm:
                b.encryption = "wpa2/wpa3"
            elif "SAE" in akm:
                b.encryption = "wpa3"
            else:
                b.encryption = "wpa2"
        elif has_wpa:
            b.encryption = "wpa"
        elif b.encryption == "wep":
            # set earlier by the privacy + no-RSN/WPA combination
            pass
        else:
            b.encryption = "open"
        b.band = _band_for(b.freq_mhz)
        if b.channel is None:
            b.channel = _channel_for(b.freq_mhz)
        bsss.append(b)

    for raw_line in output.splitlines():
        header = _BSS_HEADER_RE.match(raw_line)
        if header:
            if current is not None:
                finalize(current)
            current = BSS(bssid=header.group(1).lower(), ssid="", freq_mhz=0, signal_dbm=0.0)
            has_wpa = False
            has_rsn = False
            rsn_akm = []
            continue
        if current is None:
            continue

        m = _KV_RE.match(raw_line)
        if not m:
            continue
        key = m.group(1).strip().lower()
        value = m.group(2).strip()

        if key == "freq":
            # iw 5.x: "freq: 5180". iw 6.x: "freq: 5180.0".
            try:
                current.freq_mhz = int(float(value))
            except ValueError:
                pass
        elif key == "signal":
            # "-67.00 dBm" — keep only the number.
            try:
                current.signal_dbm = float(value.split()[0])
            except (ValueError, IndexError):
                pass
        elif key == "ssid":
            current.ssid = value
        elif key == "beacon interval":
            # "100 TUs"
            try:
                current.beacon_interval_tu = int(value.split()[0])
            except (ValueError, IndexError):
                pass
        elif key == "last seen":
            # "2400 ms ago"
            try:
                current.last_seen_ms = int(value.split()[0])
            except (ValueError, IndexError):
                pass
        elif key == "capability":
            # Privacy bit set + no RSN/WPA later => WEP. We mark it now and
            # let finalize() promote it to wpa/wpa2/wpa3 if those IEs appear.
            if "privacy" in value.lower():
                current.encryption = "wep"
        elif key == "rsn":
            has_rsn = True
        elif key == "wpa":
            has_wpa = True
        elif key.startswith("* authentication suites"):
            # "* Authentication suites: PSK SAE" — appears inside RSN block.
            rsn_akm.append(value)

    if current is not None:
        finalize(current)
    return bsss


# --- iw runner ------------------------------------------------------------

class IwRunner:
    """Thin wrapper around the ``iw`` and ``ip`` commands."""

    def __init__(self, iface: str, scan_timeout: int) -> None:
        self.iface = iface
        self.scan_timeout = scan_timeout

    def ensure_up(self) -> None:
        # Idempotent: if it is already up, this is effectively a no-op.
        subprocess.run(
            ["ip", "link", "set", self.iface, "up"],
            check=False,
            capture_output=True,
        )

    def scan(self) -> str:
        # ``iw scan`` returns non-zero on transient kernel busy errors. The
        # caller treats any failure as a scan error and re-tries on the next
        # tick — so we do NOT raise here on non-zero exit.
        result = subprocess.run(
            ["iw", "dev", self.iface, "scan"],
            check=False,
            capture_output=True,
            text=True,
            timeout=self.scan_timeout,
        )
        if result.returncode != 0:
            raise RuntimeError(
                f"iw scan failed (rc={result.returncode}): "
                f"{result.stderr.strip() or result.stdout.strip()}"
            )
        return result.stdout


# --- SSID filtering -------------------------------------------------------

def ssid_matches(ssid: str, patterns: Iterable[str]) -> bool:
    """Return True if ``ssid`` matches any of the glob patterns.

    An empty pattern list means "match everything".
    """
    patterns = list(patterns)
    if not patterns:
        return True
    if not ssid:
        # Hidden SSIDs (empty string) are dropped unless a literal "" pattern
        # is configured — there is no useful glob that "accidentally" matches
        # them.
        return False
    return any(fnmatch.fnmatchcase(ssid, p) for p in patterns)


def ssid_label(ssid: str, hash_ssid: bool) -> str:
    if not hash_ssid:
        return ssid
    digest = hashlib.sha256(ssid.encode("utf-8")).hexdigest()[:12]
    return f"sha256:{digest}"


# --- Metric collector -----------------------------------------------------

class WiFiCollector:
    """Holds gauges that are fully repopulated on every scan.

    We use plain Gauges (not custom collectors) so the same series can be
    cleared and rewritten each cycle — that way BSSIDs that disappear from
    the air drop out of /metrics within one scrape interval, instead of
    lingering forever at their last value.
    """

    def __init__(self, registry: CollectorRegistry) -> None:
        labels = ["bssid", "ssid", "channel", "band"]

        self.signal = Gauge(
            "pitale_wifi_bss_signal_dbm",
            "Signal strength of the BSS as reported by iw, in dBm "
            "(negative; closer to 0 is stronger).",
            labels,
            registry=registry,
        )
        self.freq = Gauge(
            "pitale_wifi_bss_frequency_mhz",
            "Center frequency of the BSS, in MHz.",
            labels,
            registry=registry,
        )
        self.channel_g = Gauge(
            "pitale_wifi_bss_channel",
            "Channel number derived from the frequency.",
            labels,
            registry=registry,
        )
        self.beacon = Gauge(
            "pitale_wifi_bss_beacon_interval_tu",
            "Beacon interval in 802.11 Time Units (1 TU = 1024 us).",
            labels,
            registry=registry,
        )
        self.last_seen = Gauge(
            "pitale_wifi_bss_last_seen_seconds",
            "Time since the kernel last received a frame from this BSS, "
            "in seconds (smaller = fresher).",
            labels,
            registry=registry,
        )
        self.encryption_g = Gauge(
            "pitale_wifi_bss_encryption_info",
            "Constant 1 series; the encryption flavour is in the label.",
            labels + ["encryption"],
            registry=registry,
        )

        # Per-scan summaries.
        self.scan_duration = Gauge(
            "pitale_wifi_scan_duration_seconds",
            "Wall-clock duration of the last successful scan.",
            registry=registry,
        )
        self.scan_last_success = Gauge(
            "pitale_wifi_scan_last_success_timestamp_seconds",
            "Unix timestamp of the last successful scan.",
            registry=registry,
        )
        self.scan_bss_count = Gauge(
            "pitale_wifi_scan_bss_count",
            "Number of BSSIDs returned by the last scan (pre-filter).",
            registry=registry,
        )
        self.scan_matched_count = Gauge(
            "pitale_wifi_scan_matched_count",
            "Number of BSSIDs that matched the SSID patterns and were "
            "exported as labelled series.",
            registry=registry,
        )
        self.scan_errors = Counter(
            "pitale_wifi_scan_errors_total",
            "Total number of failed scan attempts since process start.",
            registry=registry,
        )

    def _clear_per_bss(self) -> None:
        # Counter does not expose clear(); only the gauges need it.
        for g in (
            self.signal, self.freq, self.channel_g, self.beacon,
            self.last_seen, self.encryption_g,
        ):
            g.clear()

    def publish(self, bsss: list[BSS], hash_ssid: bool) -> int:
        self._clear_per_bss()
        exported = 0
        for b in bsss:
            label = ssid_label(b.ssid, hash_ssid)
            labels = (
                b.bssid,
                label,
                str(b.channel) if b.channel is not None else "",
                b.band or "",
            )
            self.signal.labels(*labels).set(b.signal_dbm)
            self.freq.labels(*labels).set(b.freq_mhz)
            if b.channel is not None:
                self.channel_g.labels(*labels).set(b.channel)
            if b.beacon_interval_tu is not None:
                self.beacon.labels(*labels).set(b.beacon_interval_tu)
            if b.last_seen_ms is not None:
                self.last_seen.labels(*labels).set(b.last_seen_ms / 1000.0)
            self.encryption_g.labels(*labels, b.encryption).set(1)
            exported += 1
        self.scan_matched_count.set(exported)
        return exported


# --- Main loop ------------------------------------------------------------

_stop = threading.Event()


def _handle_signal(signum: int, _frame) -> None:
    LOG.info("received signal %d, shutting down", signum)
    _stop.set()


def scan_loop(cfg: Config, runner: IwRunner, collector: WiFiCollector) -> None:
    while not _stop.is_set():
        cycle_start = time.monotonic()
        try:
            runner.ensure_up()
            t0 = time.monotonic()
            output = runner.scan()
            duration = time.monotonic() - t0

            all_bss = parse_iw_scan(output)
            collector.scan_bss_count.set(len(all_bss))
            kept = [b for b in all_bss if ssid_matches(b.ssid, cfg.ssid_patterns)]
            exported = collector.publish(kept, cfg.hash_ssid)

            collector.scan_duration.set(duration)
            collector.scan_last_success.set(time.time())
            LOG.info(
                "scan ok: %d BSSIDs seen, %d matched, %.2fs",
                len(all_bss), exported, duration,
            )
        except subprocess.TimeoutExpired:
            collector.scan_errors.inc()
            LOG.warning("iw scan timed out after %ds", cfg.scan_timeout)
        except Exception as e:  # noqa: BLE001 — bubble up only as a metric
            collector.scan_errors.inc()
            LOG.warning("scan failed: %s", e)

        # Sleep the remainder of the interval, but wake up early on shutdown.
        elapsed = time.monotonic() - cycle_start
        remaining = max(1.0, cfg.scan_interval - elapsed)
        _stop.wait(remaining)


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    cfg = Config()
    LOG.info(
        "starting wifi_exporter: iface=%s interval=%ds patterns=%s hash_ssid=%s",
        cfg.iface, cfg.scan_interval, cfg.ssid_patterns, cfg.hash_ssid,
    )

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    registry = CollectorRegistry()
    collector = WiFiCollector(registry)
    runner = IwRunner(cfg.iface, cfg.scan_timeout)

    start_http_server(cfg.listen_port, addr=cfg.listen_host, registry=registry)
    LOG.info("metrics http server on %s:%d", cfg.listen_host, cfg.listen_port)

    try:
        scan_loop(cfg, runner, collector)
    finally:
        LOG.info("bye")
        sys.exit(0)


if __name__ == "__main__":
    main()
