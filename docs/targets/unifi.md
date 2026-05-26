# UniFi target

Self-hosted UniFi Network controller on the Pi + metrics into
Prometheus/Grafana. Three containers:

```
   ┌────────────── pi-tale-unifi (bridge: pitale) ──────────────┐
   │                                                             │
   │   ┌──────────┐    ┌──────────────────────┐   ┌──────────┐  │
   │   │  mongo   │◄───┤ unifi-network-app    │◄──┤  unifi-  │  │
   │   │ (4.4)    │    │  UI 8443 / inform    │   │  poller  │──┼─► Prometheus
   │   └──────────┘    │   8080 / STUN 3478   │   │  :9130   │  │
   │                   └──────────────────────┘   └──────────┘  │
   └──────────────────┬─────────────────────────────────────────┘
                      │ inform 8080, STUN 3478/udp
                      ▼
              APs / switches on the LAN
```

Memory budget: ~1 GB extra (mongo 384 M cap, controller 1 G with JVM
heap pinned to 768 M, poller 64 M). Comfortable on Pi 4 / 4 GB with
core+probes running; vigilant on Pi 4 / 4 GB with extras on top.

## 1. Prerequisites

- `make up` has been run at least once (core stack creates the
  `pitale` bridge that the UniFi project attaches to as `external:
  true`).
- `compose/.env` exists. The values you need are listed in
  `compose/.env.example` under the **UniFi Network controller**
  section — copy the new keys over if your `.env` predates this layer.
- For the migration path below, **access to your current controller**
  (UDM, Cloud Key, or another server) so you can pull a backup and
  flip the inform URL on the devices.

## 2. Pick passwords and fill `compose/.env`

Edit `compose/.env`:

```
MONGO_ROOT_USER=root
MONGO_ROOT_PASS=<long random>
UNIFI_DB_USER=unifi
UNIFI_DB_PASS=<long random>
UNIFI_DB_NAME=unifi

# Left empty for now — you'll set these at step 4.
UNIFI_POLLER_USER=pitale-poller
UNIFI_POLLER_PASS=

BIND_HOST_UI=127.0.0.1
```

The poller's password stays empty for now. The container references
this variable on start, so the poller will refuse to come up until
step 4 — that is intentional.

## 3. First boot (mongo + controller)

```bash
make unifi
```

This brings up `mongo` and `unifi`. `unifi_poller` will fail-fast on
the empty `UNIFI_POLLER_PASS` and stay in a restart loop until step 4.
Ignore it for now.

The controller takes 30–90 s to come up the first time (Java + first-
boot Mongo schema). Watch the healthcheck:

```bash
docker compose -f compose/unifi.yml --env-file compose/.env ps
# wait until pitale-unifi shows "healthy"
```

## 4. Initial setup in the UI

From your workstation, open an SSH tunnel and the UI:

```bash
ssh -L 8443:localhost:8443 <pi-user>@<pi-ip>
# in another terminal / browser:
#   https://localhost:8443
```

Accept the self-signed cert (or import the controller's certificate
into your trust store later). Run through the wizard:

1. Country / timezone.
2. **Skip** "Sign in with Ubiquiti SSO" — go for the local-admin
   option. This is the controller admin, not the poller.
3. **Skip device adoption for now** — we'll bring devices in via the
   migration path at step 6, not via auto-discovery (which doesn't
   work over the bridge anyway).
4. Done.

Now create the read-only user the poller will use:

1. Settings → Admins & Users → Admins → **Add New Admin**.
2. Account type: **Local Access Only**.
3. Username: `pitale-poller` (or whatever you put in
   `UNIFI_POLLER_USER`).
4. Password: same long random string you will put in
   `UNIFI_POLLER_PASS`.
5. Role: **Limited Admin → Read Only**.
6. Save.

Put the password in `compose/.env`:

```
UNIFI_POLLER_PASS=<the password you just set>
```

Restart just the poller — no need to touch mongo or the controller:

```bash
docker compose -f compose/unifi.yml --env-file compose/.env up -d unifi_poller
docker compose -f compose/unifi.yml --env-file compose/.env logs -f unifi_poller
# look for: "Logged into [https://unifi:8443] as user [pitale-poller]"
```

## 5. Verify Prometheus is scraping

```bash
make reload-prometheus
curl -sG http://localhost:9090/api/v1/query \
  --data-urlencode 'query=up{job="unifi_poller"}' \
  | python3 -m json.tool
# expect value = "1"
```

In Grafana → Explore, run `unpoller_device_info` and you should see
zero series (no devices migrated yet) — but the metric existing
confirms the wiring.

## 6. Migrate APs and switches without losing config

Your devices are currently adopted by another controller. To move them
without re-adoption:

**a) Backup the old controller's config**

In the OLD controller's UI: `Settings → System → Backups → Download
Backup`. Save the `.unf` file locally.

**b) Restore it on the new (Pi) controller**

In the NEW controller's UI (still over the SSH tunnel):
`Settings → System → Backups → Restore`. Upload the `.unf`. The
controller restarts, restoring sites, SSIDs, port profiles, **and the
device keys**.

Reload the page; under Devices you'll see your APs and switches
listed but `Disconnected` — they are still pointing at the OLD
controller's inform URL.

**c) Flip the inform URL on the devices**

Two ways. From easiest to most reliable:

- **Via the OLD controller's UI** (best): `Settings → System →
  Application Configuration → Override Inform Host` →
  `http://<pi-ip>:8080`. Apply. Each device picks up the new URL on
  its next inform (≤30 s) and reconnects to the Pi automatically
  because the keys already match.
- **By SSH to each device** (fallback): if a device doesn't pick up
  the override (some old firmwares ignore it),
  ```bash
  ssh ubnt@<device-ip>     # default password ubnt unless you changed it
  set-inform http://<pi-ip>:8080/inform
  ```

Watch the new controller's Devices page — each device flips from
`Disconnected` → `Pending` → `Connected` in under a minute.

**d) Shut down the old controller**

Once every device shows `Connected` on the new controller and traffic
is flowing, stop the old controller. Keep its backup .unf and a
snapshot of its config for at least a week before reclaiming the host.

## 7. Confirm metrics

`unpoller_device_info` should now have one series per device. Suggested
quick checks in Grafana → Explore:

```promql
# Number of clients per site
sum by (site) (unpoller_subsystem_status_num_user)

# Per-AP client count
unpoller_client_info{type="ap"}

# Switch PoE budget vs used
unpoller_device_switch_total_power_watts
```

A provisioned UniFi dashboard ships in a follow-up step (TODO once
the metric set is confirmed in your setup).

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `pitale-unifi` stuck in `starting` | Java warming up | Wait up to 2 min on first boot; check `docker logs pitale-unifi` for "Started application" |
| `pitale-unifi` exits with auth error to mongo | Mongo init script never ran (volume not empty) | `docker compose -f compose/unifi.yml down`, `sudo rm -rf data/unifi/db`, `make unifi` again |
| `unifi_poller` keeps restarting | `UNIFI_POLLER_PASS` empty or wrong | Set the password and `docker compose -f compose/unifi.yml up -d unifi_poller` |
| Devices stuck in `Pending Adoption` on the new controller | Inform URL flipped but device key doesn't match (no restore done) | Either restore the backup first, or factory-reset the device and re-adopt |
| `up{job="unifi_poller"}` is 0 but the container is healthy | Prometheus hasn't been reloaded after the new scrape job was added | `make reload-prometheus` |
| Controller UI loads but devices show `Adopt Failed` | Old controller still has a stale lock on them | Stop the old controller and click `Adopt` again |
| Mongo OOM-killed | Working set bigger than 384 M cap | Raise `mem_limit` for `mongo` in `compose/unifi.yml`; expect ~250 M baseline per controller |

## Backup

`scripts/backup.sh` already tars `data/` whole, so `data/unifi/db` and
`data/unifi/app` are included. A controller-level backup (the `.unf`
file from `Settings → System → Backups`) is also valuable because it
is portable to another controller — keep one on hand.

## Where the config lives

| Path | Purpose |
|---|---|
| `compose/unifi.yml` | The three services |
| `compose/.env` | Credentials (gitignored) |
| `unifi/mongo-init.sh` | One-shot Mongo init: creates the app user on first boot |
| `data/unifi/db/` | MongoDB on-disk state |
| `data/unifi/app/` | UniFi controller state (sites, devices, logs, certs) |
| `prometheus/prometheus.yml` | `unifi_poller` scrape job |
| `prometheus/rules/unifi.yml` | Alerts: poller down, controller unreachable, device down/restart loop |
