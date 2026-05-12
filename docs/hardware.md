# Hardware

pi-tale runs on a single Raspberry Pi. The pieces below are what we test
against; everything else is best-effort.

## Recommended bill of materials

| Item                | Reason                                                                                     |
| ------------------- | ------------------------------------------------------------------------------------------ |
| Raspberry Pi 5 8 GB | Best price/performance. Pi 4 4 GB works for ≤10 devices, Pi 4 8 GB or Pi 5 for larger sites. |
| Active cooler       | The stack is mostly idle but spikes during compaction. Keep the SoC under 70 °C.            |
| Official PSU (27 W) | USB-PD undervoltage is the #1 cause of mysterious problems.                                 |
| microSD 32 GB A2    | Boot only — never put TSDB or logs here.                                                    |
| USB 3.0 SSD 256 GB+ | Cheap, fast, swappable. Brands with sustained write performance (Samsung, Crucial, WD).      |
| Alternative: NVMe HAT | Pi 5 only. Faster, neater. Adds cost.                                                     |
| Gigabit Ethernet    | The Pi must be wired to your UniFi network.                                                |
| (Optional) Alfa AWUS036ACM / AWUS036NHA | Monitor-mode WiFi adapter for the RF probe in `exporters/wifi/`.        |
| (Optional) PoE HAT  | Powers the Pi from a PoE UniFi switch, one cable does everything.                          |

## Why not the microSD?

Prometheus writes constantly. Loki writes constantly. Grafana logs in
the background. Even modest "endurance" microSD cards die in months
under this load. Use an SSD — the rest of the stack assumes it.

## Power

If you ever see `Throttled: 0x50000` in `vcgencmd get_throttled`, the
PSU is undervolting under load. Fix the power supply first; ignore the
metric noise everything else produces until then.

## Cooling

A passive heatsink is fine on a Pi 4 in a 22 °C office. A Pi 5 generates
more heat — get the active cooler, especially in a closet.

## Networking notes

- The Pi should sit on the **management VLAN** if you have one. It needs
  to reach the UniFi controller, the switches, the APs, and anything you
  want it to ping.
- Give it a static DHCP reservation; Grafana URLs reference its IP.
- Outbound HTTPS to docker.io and the OCI mirrors must work for
  `docker compose pull` to update images.
