# Troubleshooting

A growing list. PRs welcome.

## "GRAFANA_ADMIN_PASSWORD is required"

`compose/.env` is missing or empty. Either:

```bash
cp compose/.env.example compose/.env
nano compose/.env   # set GRAFANA_ADMIN_PASSWORD
```

…or `bootstrap/install.sh` will do that for you.

## Prometheus container is stuck in `Restarting`

Most often: ownership on `data/prometheus`. The image runs as UID 65534.

```bash
sudo chown -R 65534:65534 data/prometheus
sudo docker compose -f compose/core.yml restart prometheus
```

## Grafana shows "Loki: connection refused"

Loki takes a few seconds to become ready. If it persists:

```bash
docker compose -f compose/core.yml logs loki | tail -50
```

Look for schema errors. If you changed the storage backend, you may need
to wipe `data/loki` (this loses your log history).

## `vcgencmd get_throttled` is non-zero

Undervoltage (`0x1`), throttling (`0x2`), capped (`0x4`). Fix the PSU
first. See [`hardware.md`](hardware.md).

## "no space left on device"

Either the SSD is full or you forgot to point pi-tale at the SSD and it
is filling the microSD.

```bash
df -h /mnt/datos
df -h ./data
```

If `./data` is on the microSD, set up the SSD and re-run
`bootstrap/install.sh`.

## "I get alerts about everything for 30 minutes after a restart"

`for: 5m` rules need data older than 5 minutes to evaluate cleanly. The
default rules already use ≥5 m windows; if you wrote stricter rules,
relax them.

## Alertmanager UI shows my alert but I get no notification

Receivers are commented out by default. Edit
`alertmanager/alertmanager.yml`, uncomment Telegram and/or email, then:

```bash
docker compose -f compose/core.yml restart alertmanager
```
