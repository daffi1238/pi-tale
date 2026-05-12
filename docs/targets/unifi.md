# UniFi target

Status: stub. Lives in `compose/unifi.yml`.

Planned contents:

- **UniFi Network Application** running locally on the Pi (so you do not
  depend on a cloud controller for visibility).
- **unifi-poller** scraping the controller API and exposing
  per-device, per-client and per-site metrics to Prometheus.
- Provisioned Grafana dashboards for AP load, PoE budget per switch,
  client roaming and DPI by site.

What you will need to put in `compose/.env` once this is wired:

```
UNIFI_CONTROLLER_HOST=https://unifi.local:8443
UNIFI_USERNAME=monitor
UNIFI_PASSWORD=...
UNIFI_SITE=default
```

The "monitor" user should be a read-only local UniFi account, not your
admin account.
