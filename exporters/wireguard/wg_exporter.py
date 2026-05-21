"""pi-tale — WireGuard exporter.

Reads `wg show all dump` on an interval and exposes per-peer metrics on
:9586/metrics in the same shape as the (no-longer-on-Docker-Hub)
prometheus_wireguard_exporter, so committed alert rules and dashboards
that targeted that exporter keep working unchanged.

Exposed:

  wireguard_latest_handshake_seconds{interface, peer}   gauge (unix ts)
  wireguard_sent_bytes_total{interface, peer}           counter
  wireguard_received_bytes_total{interface, peer}       counter
  wireguard_allowed_ips_info{interface, peer, ips}      gauge (=1)
  wireguard_peers_count{interface}                      gauge
  wireguard_scrape_errors_total                         counter
  wireguard_scrape_last_success_timestamp_seconds       gauge

Runtime expectation: container is started with `network_mode: host` and
`cap_add: [NET_ADMIN]`. The wg netlink interface lives in the host
network namespace; without host networking the exporter sees no wg
interfaces.
"""

from __future__ import annotations

import logging
import os
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass

from prometheus_client import (
    CollectorRegistry,
    Counter,
    Gauge,
    start_http_server,
)


LOG = logging.getLogger("wg_exporter")

# --- config ---------------------------------------------------------------

def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        LOG.warning("invalid int for %s=%r, using default %d", name, raw, default)
        return default


@dataclass(frozen=True)
class Config:
    interval: int = _env_int("WG_SCAN_INTERVAL", 30)
    listen_host: str = os.environ.get("WG_LISTEN_HOST", "0.0.0.0").strip() or "0.0.0.0"
    listen_port: int = _env_int("WG_LISTEN_PORT", 9586)


# --- parsing --------------------------------------------------------------

# `wg show all dump` produces lines like (TSV):
#
#   <iface>  <priv-key>  <pub-key>  <listen-port>  <fwmark>
#   <iface>  <peer-pub>  <preshared>  <endpoint>  <allowed-ips>  <ts>  <rx>  <tx>  <keepalive>
#
# The first line per interface is the interface itself; subsequent lines
# are its peers. `wg show all dump` interleaves multiple interfaces.

INTERFACE_FIELDS = 5
PEER_FIELDS = 9


@dataclass
class Peer:
    interface: str
    public_key: str
    endpoint: str
    allowed_ips: str
    latest_handshake: int        # unix seconds; 0 = never
    received_bytes: int
    sent_bytes: int
    keepalive: str               # "off" or int seconds


def parse_dump(output: str) -> list[Peer]:
    peers: list[Peer] = []
    for raw in output.splitlines():
        fields = raw.split("\t")
        if len(fields) == INTERFACE_FIELDS:
            # Interface line, skip — peers carry the iface name already.
            continue
        if len(fields) != PEER_FIELDS:
            LOG.debug("ignoring line with %d fields: %r", len(fields), raw)
            continue
        try:
            peers.append(Peer(
                interface=fields[0],
                public_key=fields[1],
                # field[2] = preshared key (or "(none)")
                endpoint=fields[3],
                allowed_ips=fields[4],
                latest_handshake=int(fields[5]),
                received_bytes=int(fields[6]),
                sent_bytes=int(fields[7]),
                keepalive=fields[8],
            ))
        except (ValueError, IndexError) as e:
            LOG.warning("could not parse peer line %r: %s", raw, e)
    return peers


# --- wg runner ------------------------------------------------------------

class WgRunner:
    def show_dump(self, timeout: int = 5) -> str:
        # `wg show all dump` requires CAP_NET_ADMIN to read the netlink
        # interface. Failure here means either no wg interface on this
        # host, or the cap is missing — both surface to the caller as a
        # scrape error.
        result = subprocess.run(
            ["wg", "show", "all", "dump"],
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        if result.returncode != 0:
            raise RuntimeError(
                f"wg show failed (rc={result.returncode}): "
                f"{result.stderr.strip() or result.stdout.strip()}"
            )
        return result.stdout


# --- collector ------------------------------------------------------------

class WgCollector:
    def __init__(self, registry: CollectorRegistry) -> None:
        labels = ["interface", "peer"]

        self.handshake = Gauge(
            "wireguard_latest_handshake_seconds",
            "Unix timestamp of the most recent handshake with this peer "
            "(0 if never).",
            labels,
            registry=registry,
        )
        self.tx = Gauge(
            "wireguard_sent_bytes_total",
            "Bytes sent to this peer since wg0 came up. Gauge, not "
            "counter — wg's counter resets every interface restart.",
            labels,
            registry=registry,
        )
        self.rx = Gauge(
            "wireguard_received_bytes_total",
            "Bytes received from this peer since wg0 came up.",
            labels,
            registry=registry,
        )
        self.allowed_ips = Gauge(
            "wireguard_allowed_ips_info",
            "Constant 1 series — the allowed-ips block is in the label.",
            labels + ["allowed_ips"],
            registry=registry,
        )
        self.peers_count = Gauge(
            "wireguard_peers_count",
            "Number of peers currently registered on the interface.",
            ["interface"],
            registry=registry,
        )

        self.last_success = Gauge(
            "wireguard_scrape_last_success_timestamp_seconds",
            "Unix timestamp of the last successful `wg show` call.",
            registry=registry,
        )
        self.scrape_errors = Counter(
            "wireguard_scrape_errors_total",
            "Total failed scrape attempts since process start.",
            registry=registry,
        )

    def _clear_per_peer(self) -> None:
        for g in (self.handshake, self.tx, self.rx, self.allowed_ips, self.peers_count):
            g.clear()

    def publish(self, peers: list[Peer]) -> None:
        self._clear_per_peer()
        by_iface: dict[str, int] = {}
        for p in peers:
            lbls = (p.interface, p.public_key)
            self.handshake.labels(*lbls).set(p.latest_handshake)
            self.tx.labels(*lbls).set(p.sent_bytes)
            self.rx.labels(*lbls).set(p.received_bytes)
            self.allowed_ips.labels(*lbls, p.allowed_ips).set(1)
            by_iface[p.interface] = by_iface.get(p.interface, 0) + 1
        for iface, n in by_iface.items():
            self.peers_count.labels(iface).set(n)


# --- main loop ------------------------------------------------------------

_stop = threading.Event()


def _handle_signal(signum: int, _frame) -> None:
    LOG.info("received signal %d, shutting down", signum)
    _stop.set()


def scan_loop(cfg: Config, runner: WgRunner, collector: WgCollector) -> None:
    while not _stop.is_set():
        cycle_start = time.monotonic()
        try:
            output = runner.show_dump()
            peers = parse_dump(output)
            collector.publish(peers)
            collector.last_success.set(time.time())
            LOG.info("ok: %d peer(s) across %d interface(s)",
                     len(peers), len({p.interface for p in peers}))
        except subprocess.TimeoutExpired:
            collector.scrape_errors.inc()
            LOG.warning("wg show timed out")
        except Exception as e:  # noqa: BLE001
            collector.scrape_errors.inc()
            LOG.warning("scrape failed: %s", e)

        elapsed = time.monotonic() - cycle_start
        remaining = max(1.0, cfg.interval - elapsed)
        _stop.wait(remaining)


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    cfg = Config()
    LOG.info("starting wg_exporter: interval=%ds listen=%s:%d",
             cfg.interval, cfg.listen_host, cfg.listen_port)

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    registry = CollectorRegistry()
    collector = WgCollector(registry)
    runner = WgRunner()

    start_http_server(cfg.listen_port, addr=cfg.listen_host, registry=registry)
    LOG.info("metrics http server on %s:%d", cfg.listen_host, cfg.listen_port)

    try:
        scan_loop(cfg, runner, collector)
    finally:
        LOG.info("bye")
        sys.exit(0)


if __name__ == "__main__":
    main()
