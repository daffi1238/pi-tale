# Example: home office / serious homelab

Status: stub.

Target deployment shape:

- 1× Raspberry Pi 4 4 GB with USB SSD.
- 1× UniFi Dream Router or Cloud Gateway.
- 1–2× UniFi APs.
- A NAS, a desktop, a couple of IoT devices.

Will contain:

- Minimal `.env` template.
- ICMP probes for the gateway, NAS and a couple of public targets.
- One Grafana dashboard ("home overview") with WAN/LAN latency, NAS
  reachability and disk space on the Pi.
