# pi-tale — WireGuard gateway.
#
# Single-purpose container: terminates the WG tunnel inside its own
# network namespace and DNAT-forwards two specific paths only:
#
#   pitale bridge :{9100,9080,9113,9187}  →  wg0 :10.50.0.2:<same port>
#   wg0           :3100                   →  pitale bridge :loki:3100
#
# Nothing else can flow. The Pi host's netns NEVER sees wg0, so a
# compromised VPS cannot reach sshd, Grafana, Prometheus UI or anything
# else bound to 0.0.0.0 on the Pi — only the gateway and the two ports
# above.
#
# Requires `cap_add: NET_ADMIN`, `--device=/dev/net/tun`, and sysctl
# `net.ipv4.ip_forward=1` set in compose. Run as root inside the
# container: NET_ADMIN applied to root is the standard path; ambient
# capabilities for a non-root user pull in a lot of plumbing for a
# single-tenant probe.

FROM debian:bookworm-slim

# wireguard-tools: wg, wg-quick.
# iptables:        nat + forward rules.
# iproute2:        wg-quick relies on `ip`.
# openresolv:      provides `resolvconf` so wg-quick can honour the
#                  optional `DNS = ...` line in user-supplied wg0.conf.
#                  Functionally unused inside the gateway (no process
#                  here does DNS over the tunnel), but if the file
#                  carries the line, wg-quick refuses to start without it.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        wireguard-tools \
        iptables \
        iproute2 \
        openresolv \
        ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# wg0.conf is bind-mounted at runtime from data/wireguard/ (user-
# managed; see data/wireguard/wg0.conf.example). We deliberately do
# NOT copy it into the image — it contains the private key.

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
