# pi-tale — WiFi RF exporter.
#
# Runtime expectation: container is started with `network_mode: host` and
# `cap_add: [NET_ADMIN, NET_RAW]`. The wlan interface must exist on the
# host first (see bootstrap/wifi-driver-setup.sh).
#
# We run as root on purpose: NET_ADMIN/NET_RAW added via --cap-add only
# apply to root unless we set ambient capabilities, and that pulls in a
# lot of extra plumbing for no real benefit on a single-tenant probe.
# Same pattern as the blackbox_exporter service.

FROM python:3.12-slim-bookworm

# iw / iproute2 must come from the distro (no pip equivalents). tini gives
# us a real PID 1 so SIGTERM from `docker stop` is forwarded to Python.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        iw \
        iproute2 \
        tini \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY wifi_exporter.py ./

EXPOSE 9116

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["python", "-u", "wifi_exporter.py"]
