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

# Inbound forwards: services on the pitale bridge that overlay peers reach
# via the gateway's wg0 address (10.0.0.125). Space-separated "host:port".
# We resolve each name via Docker DNS rather than hard-coding an IP.
#
#   loki:3100    — VPS Alloy/Promtail pushes logs here (required).
#   grafana:3000 — dashboards viewable from the VPN at 10.0.0.125:3000.
#
# SECURITY: each entry widens what a compromised VPS (or any overlay peer)
# can reach on the Pi side. Keep this list minimal. Drop grafana:3000 to
# reach Grafana only via SSH tunnel to localhost:3000.
INBOUND_FORWARDS="${INBOUND_FORWARDS:-loki:3100 grafana:3000}"

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

# ----------------------------------------------------------------------------
# Resolve inbound-forward targets BEFORE wg-quick.
# ----------------------------------------------------------------------------
#
# wg-quick applies the `DNS =` line from wg0.conf, which rewrites
# /etc/resolv.conf and drops Docker's embedded resolver (127.0.0.11). After
# that, service names like `loki` no longer resolve. So resolve every
# INBOUND_FORWARDS host to an IP now, while Docker DNS is still in place, and
# stash "port:ip" pairs for the rule-install pass further down.
RESOLVED_FORWARDS=""
for entry in ${INBOUND_FORWARDS}; do
  svc_host="${entry%%:*}"
  svc_port="${entry##*:}"

  svc_ip=""
  i=0
  while [ "${i}" -lt 30 ]; do
    svc_ip="$(getent hosts "${svc_host}" 2>/dev/null | awk '{print $1; exit}')" || true
    [ -n "${svc_ip}" ] && break
    i=$((i + 1))
    sleep 2
  done

  if [ -z "${svc_ip}" ]; then
    warn "${svc_host} did not resolve in 60s — inbound forward ${entry} disabled."
    warn "Bring up the core stack ('make up') and restart this container."
    continue
  fi

  log "Resolved ${svc_host} → ${svc_ip} (inbound ${WG_IFACE}:${svc_port})"
  RESOLVED_FORWARDS="${RESOLVED_FORWARDS} ${svc_port}:${svc_ip}"
done

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

# --- INBOUND: overlay peers → services on the pitale bridge ---
#
# A packet arrives on wg0 with dst=10.0.0.125 (the gateway) and the service
# port. We DNAT it to the service's actual bridge IP (resolved above, before
# wg-quick clobbered DNS) and MASQUERADE on the way out so the service sees a
# valid bridge-local source.
for pair in ${RESOLVED_FORWARDS}; do
  svc_port="${pair%%:*}"
  svc_ip="${pair##*:}"

  log "Inbound forward ${WG_IFACE}:${svc_port} → ${svc_ip}:${svc_port}"
  iptables -t nat -A PREROUTING -i "${WG_IFACE}" -p tcp --dport "${svc_port}" \
    -j DNAT --to-destination "${svc_ip}:${svc_port}"
  iptables -A FORWARD -i "${WG_IFACE}" -o eth0 -d "${svc_ip}" -j ACCEPT
  iptables -A FORWARD -i eth0 -o "${WG_IFACE}" -s "${svc_ip}" -j ACCEPT
  iptables -t nat -A POSTROUTING -o eth0 -d "${svc_ip}" -j MASQUERADE
done

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
