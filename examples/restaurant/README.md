# Example: restaurant

Status: stub.

Target deployment shape:

- 1× Raspberry Pi 4 4 GB on the office shelf.
- 1× UniFi gateway.
- 2× UniFi APs (dining room + kitchen).
- 1× POS terminal, 1× kitchen printer, 1× card reader.

Will contain:

- `.env` template tuned for hostile-RF environments (lots of microwave
  oven noise, beware 2.4 GHz).
- ICMP probes for POS, printer and the card reader's gateway — those
  are the things that get reported as "the system is down" first.
- A small dashboard focused on per-AP retry rate and POS reachability.
