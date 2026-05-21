# pi-tale — WireGuard exporter.
#
# Container needs `network_mode: host` and `cap_add: [NET_ADMIN]`. The
# wg netlink interface lives in the host network namespace; without host
# networking the exporter sees no wg interfaces.
#
# Same root-by-default pattern as blackbox/wifi_exporter: NET_ADMIN
# applied to a non-root user requires ambient capabilities, which add
# complexity with no real benefit on a single-tenant Pi.

FROM python:3.12-slim-bookworm

# wireguard-tools brings the `wg` userspace tool. tini for proper PID 1.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        wireguard-tools \
        tini \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY wg_exporter.py ./

EXPOSE 9586

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["python", "-u", "wg_exporter.py"]
