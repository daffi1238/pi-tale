#!/bin/sh
# pi-tale — WireGuard gateway entrypoint.
#
# Brings up wg0 from the user-managed config bind-mounted at
# /wg/wg0.conf (host: data/wireguard/wg0.conf), installs two narrowly-
# scoped iptables forwarding paths, then idles waiting for SIGTERM.
# Idempotent on container restart (wg-quick down + up).

set -eu

WG_IFACE="${WG_IFACE:-wg0}"
WG_CONF_SRC="/wg/wg0.conf"
WG_CONF="/etc/wireguard/${WG_IFACE}.conf"

VPS_TARGET_IP="${VPS_TARGET_IP:-10.50.0.2}"
# Space-separated list. Mirror this in the prometheus/targets/vps-*-main.yml
# files: each target uses the gateway as host, same port number.
VPS_TARGET_PORTS="${VPS_TARGET_PORTS:-9100 9080 9113 9187}"

# Inbound from VPS Promtail to Loki. Loki lives on the pitale bridge in
# the core compose project; we resolve its name via Docker DNS rather
# than hard-coding an IP.
LOKI_HOST="${LOKI_HOST:-loki}"
LOKI_PORT="${LOKI_PORT:-3100}"

log()  { printf '[wg-gw] %s\n'   "$*"; }
warn() { printf '[wg-gw] [!] %s\n' "$*" >&2; }
fail() { printf '[wg-gw] [x] %s\n' "$*" >&2; exit 1; }

if [ ! -f "${WG_CONF_SRC}" ]; then
  fail "${WG_CONF_SRC} not found. Place your wg0.conf at data/wireguard/wg0.conf on the host (see data/wireguard/wg0.conf.example)."
fi

# wg-quick wants the conf in /etc/wireguard/. The mounted file is RO and
# contains the private key, so we copy to a writable in-container
# location and lock perms.
mkdir -p /etc/wireguard
cp "${WG_CONF_SRC}" "${WG_CONF}"
chmod 0600 "${WG_CONF}"

# Wait for Loki DNS. Loki lives in a different compose project so
# `depends_on` doesn't apply across projects; this loop is the equivalent.
log "Waiting for ${LOKI_HOST} DNS to resolve..."
LOKI_IP=""
i=0
while [ "${i}" -lt 30 ]; do
  LOKI_IP="$(getent hosts "${LOKI_HOST}" 2>/dev/null | awk '{print $1; exit}')" || true
  [ -n "${LOKI_IP}" ] && break
  i=$((i + 1))
  sleep 2
done

if [ -z "${LOKI_IP}" ]; then
  warn "${LOKI_HOST} did not resolve in 60s — inbound log forwarding disabled."
  warn "Bring up the core stack ('make up') and restart this container."
else
  log "Resolved ${LOKI_HOST} → ${LOKI_IP}"
fi

# Bring up the tunnel. wg-quick handles routes (it adds 10.50.0.0/24 dev wg0
# automatically thanks to AllowedIPs).
log "Bringing up ${WG_IFACE}"
wg-quick up "${WG_IFACE}"

# ----------------------------------------------------------------------------
# Forwarding rules
# ----------------------------------------------------------------------------
#
# We rely on conntrack to handle the reply direction; no explicit ESTABLISHED
# rule is needed in FORWARD as long as the default policy is ACCEPT (which it
# is in a fresh container netns).

log "Installing forwarding rules"

# --- OUTBOUND: pitale bridge → VPS exporters via wg0 ---
#
# Prometheus scrapes wireguard_gateway:9100, wireguard_gateway:9080, etc.
# DNAT in PREROUTING rewrites the destination to the VPS over wg0.
for port in ${VPS_TARGET_PORTS}; do
  iptables -t nat -A PREROUTING -i eth0 -p tcp --dport "${port}" \
    -j DNAT --to-destination "${VPS_TARGET_IP}:${port}"
done
iptables -A FORWARD -i eth0 -o "${WG_IFACE}" -d "${VPS_TARGET_IP}" -j ACCEPT
iptables -A FORWARD -i "${WG_IFACE}" -o eth0 -s "${VPS_TARGET_IP}" -j ACCEPT
# MASQUERADE so the VPS sees the connection sourced from 10.50.0.1 (the
# gateway's own wg0 address). Otherwise the source IP would be the pitale
# bridge IP, which the VPS has no route back to.
iptables -t nat -A POSTROUTING -o "${WG_IFACE}" -d "${VPS_TARGET_IP}" -j MASQUERADE

# --- INBOUND: VPS Promtail → Loki on the pitale bridge ---
#
# VPS Promtail dials http://10.50.0.1:${LOKI_PORT}/loki/api/v1/push. The
# packet arrives on wg0 with dst=10.50.0.1 (the gateway). We DNAT it to
# Loki's actual bridge IP and MASQUERADE on the way out so Loki sees a
# valid bridge-local source.
if [ -n "${LOKI_IP}" ]; then
  iptables -t nat -A PREROUTING -i "${WG_IFACE}" -p tcp --dport "${LOKI_PORT}" \
    -j DNAT --to-destination "${LOKI_IP}:${LOKI_PORT}"
  iptables -A FORWARD -i "${WG_IFACE}" -o eth0 -d "${LOKI_IP}" -j ACCEPT
  iptables -A FORWARD -i eth0 -o "${WG_IFACE}" -s "${LOKI_IP}" -j ACCEPT
  iptables -t nat -A POSTROUTING -o eth0 -d "${LOKI_IP}" -j MASQUERADE
fi

log "Ready. Current wg state:"
wg show "${WG_IFACE}" || true

# ----------------------------------------------------------------------------
# Wait for SIGTERM
# ----------------------------------------------------------------------------

cleanup() {
  log "Bringing down ${WG_IFACE}"
  wg-quick down "${WG_IFACE}" 2>/dev/null || true
  exit 0
}
trap cleanup TERM INT

# `tail` is the smallest "sleep until signal" trick we can ship in a slim
# image. Backgrounding it + `wait` is what makes the trap fire promptly.
tail -f /dev/null &
wait $!
