# Example: small hotel

Status: stub.

Target deployment shape:

- 1× Raspberry Pi 5 4 GB in the IT closet, PoE-powered.
- 3× UniFi access points (lobby, floor 1, floor 2).
- 1× UniFi switch (8-port PoE).
- 2× IP cameras at the entrance and parking lot.
- A handful of staff laptops and a POS terminal.

Will contain:

- A pre-filled `compose/.env` template (no secrets — placeholders).
- `prometheus/targets/blackbox-icmp-hotel.yml` with the gateway, APs,
  switch and cameras.
- A Grafana dashboard JSON tuned for this size of site (one screen,
  no scrolling).
- A short runbook for the most common alerts (AP offline, PoE budget
  near limit, camera unreachable).
