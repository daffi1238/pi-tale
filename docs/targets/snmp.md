# SNMP target

Status: stub. Lives in `compose/probes.yml`.

Planned contents:

- `snmp_exporter` configured for SNMP v2c by default, v3 supported.
- A short generator config for common Ubiquiti switches and a few
  popular UPS models (APC, Eaton).
- Prometheus jobs that read targets from
  `prometheus/targets/snmp-*.yml` via file_sd.

`.env` variables to be added:

```
SNMP_COMMUNITY=public
```

(Keep this credential out of the repo.)
