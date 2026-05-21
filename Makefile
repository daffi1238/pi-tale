# pi-tale — operational shortcuts.
#
# Each compose file declares its own `name:` (pi-tale-core,
# pi-tale-probes, pi-tale-extras, pi-tale-unifi). We invoke them
# INDEPENDENTLY rather than stacking with -f a.yml -f b.yml — stacking
# merges into a single project, which collides with the running ones
# and triggers "container name already in use" errors on the second
# stack. Each target here drives exactly one project.
#
# Quick tour:
#   make help            list every target
#   make up              bring up core (the baseline stack)
#   make probes          add WiFi probe alongside core
#   make extras          add Uptime Kuma alongside core
#   make all             core + probes + extras
#   make ps              what is currently running
#   make logs SERVICE=x  tail logs of `x` in the core stack
#   make backup          run scripts/backup.sh
#   make restore ARCHIVE=path/to/file.tar.gz

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# ----- config -----

ENV_FILE := compose/.env
COMPOSE  := docker compose

CORE_FILE      := compose/core.yml
PROBES_FILE    := compose/probes.yml
EXTRAS_FILE    := compose/extras.yml
UNIFI_FILE     := compose/unifi.yml
WIREGUARD_FILE := compose/wireguard.yml

CORE_PROJECT      := pi-tale-core
PROBES_PROJECT    := pi-tale-probes
EXTRAS_PROJECT    := pi-tale-extras
UNIFI_PROJECT     := pi-tale-unifi
WIREGUARD_PROJECT := pi-tale-wireguard

# Stack-specific flag bundles. Used as `$(COMPOSE) $(core_args) <verb>`.
core_args      := -f $(CORE_FILE)      --env-file $(ENV_FILE)
probes_args    := -f $(PROBES_FILE)    --env-file $(ENV_FILE)
extras_args    := -f $(EXTRAS_FILE)    --env-file $(ENV_FILE)
unifi_args     := -f $(UNIFI_FILE)     --env-file $(ENV_FILE)
wireguard_args := -f $(WIREGUARD_FILE) --env-file $(ENV_FILE)

.PHONY: help up probes extras unifi wireguard all down restart ps logs \
        pull build config validate \
        reload-prometheus reload-alertmanager reload-blackbox \
        telegram-setup secrets-setup wireguard-status wireguard-down \
        backup restore

# ----- discoverability -----

help: ## list available targets
	@awk 'BEGIN{FS=":.*?## "} \
	      /^[a-zA-Z0-9_-]+:.*## / {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' \
	      $(MAKEFILE_LIST) | sort

# ----- lifecycle -----

up: ## start core (Prometheus/Grafana/Loki/Alertmanager + base exporters)
	$(COMPOSE) $(core_args) up -d

probes: ## start probes stack (wifi_exporter — needs core to be up)
	$(COMPOSE) $(probes_args) up -d

extras: ## start extras stack (Uptime Kuma)
	$(COMPOSE) $(extras_args) up -d

unifi: ## start UniFi stack (stub — no services yet)
	$(COMPOSE) $(unifi_args) up -d

wireguard: ## start the WireGuard gateway + exporter (needs data/wireguard/wg0.conf first)
	$(COMPOSE) $(wireguard_args) up -d

all: up probes extras ## start core + probes + extras (UniFi is stub-only)

# `-` prefix: keep going if a stack isn't running.
down: ## stop every pi-tale stack
	-$(COMPOSE) $(wireguard_args) down
	-$(COMPOSE) $(unifi_args)     down
	-$(COMPOSE) $(extras_args)    down
	-$(COMPOSE) $(probes_args)    down
	-$(COMPOSE) $(core_args)      down

wireguard-down: ## stop just the WireGuard gateway (tunnel goes down)
	$(COMPOSE) $(wireguard_args) down

restart: down all ## stop then start core + probes + extras

# ----- inspection -----

# All pi-tale services share the `pitale-` name prefix (set explicitly
# via `container_name:` in every compose file). `--filter name=...` with
# a regex anchor is the only docker-side filter that ORs cleanly across
# our four projects — multi-valued `--filter label=k=v` is ANDed.
ps: ## list every running pi-tale container with status and ports
	@docker ps --filter "name=^pitale-" \
	  --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Defaults to core because that is where 99% of debugging starts.
# `make logs SERVICE=loki` to scope to one service.
logs: ## tail logs (SERVICE=name to scope, default: all of core)
	$(COMPOSE) $(core_args) logs -f --tail 100 $(SERVICE)

# ----- maintenance -----

# `pull` on probes will warn about wifi_exporter (locally built); that
# is harmless. `unifi` is a stub with no services so we skip it.
pull: ## docker compose pull for every stack with images to pull
	$(COMPOSE) $(core_args)   pull
	$(COMPOSE) $(probes_args) pull || true
	$(COMPOSE) $(extras_args) pull

build: ## (re)build locally built images (currently just wifi_exporter)
	$(COMPOSE) $(probes_args) build

# ----- validation (also run in CI) -----

config: ## `docker compose config -q` for every compose file
	$(COMPOSE) -f $(CORE_FILE)      config -q
	$(COMPOSE) -f $(PROBES_FILE)    config -q
	$(COMPOSE) -f $(EXTRAS_FILE)    config -q
	$(COMPOSE) -f $(UNIFI_FILE)     config -q
	$(COMPOSE) -f $(WIREGUARD_FILE) config -q

validate: config ## alias for `config`

# ----- runtime ops -----

# These avoid a full container restart when you only changed config.
reload-prometheus: ## POST /-/reload to Prometheus (hot reload, no downtime)
	@curl -sSf -X POST http://localhost:9090/-/reload && echo "[ok] prometheus reloaded"

reload-alertmanager: ## POST /-/reload to Alertmanager (re-reads alertmanager.yml + bot_token_file)
	@curl -sSf -X POST http://localhost:9093/-/reload && echo "[ok] alertmanager reloaded"

reload-blackbox: ## SIGHUP blackbox_exporter so it re-reads blackbox.yml
	docker kill -s SIGHUP pitale-blackbox-exporter

# ----- secrets -----

# Reads TELEGRAM_BOT_TOKEN from compose/.env (or accepts TOKEN=...) and
# writes it to data/alertmanager/secrets/telegram_bot_token, then reloads
# alertmanager. Wraps `sudo` because the target directory is owned by
# alertmanager's uid (65534) per bootstrap/install.sh.
telegram-setup: ## install the Telegram bot token (sudo; reads compose/.env or TOKEN=...)
	@sudo scripts/telegram-setup.sh $(TOKEN)

# Reads GRAFANA_ADMIN_PASSWORD (required) and SMTP_PASSWORD (optional)
# from compose/.env and writes them to data/<service>/secrets/<file>,
# so Grafana and Alertmanager pick them up via their native `*_FILE` /
# `*_password_file` directives instead of in plain env / YAML.
secrets-setup: ## install Grafana admin + SMTP password secret files (sudo; reads compose/.env)
	@sudo scripts/secrets-setup.sh

wireguard-status: ## inspect the tunnel from inside the gateway container
	@docker exec pitale-wireguard-gateway wg show wg0 \
	  || echo "[!] gateway container not running. Run: make wireguard"

# ----- backup / restore -----

# scripts/backup.sh internally stops and restarts the running stacks,
# so calling it via make is just a friendlier wrapper.
backup: ## scripts/backup.sh (pass FLAGS='--live --include-env --dest /mnt/usb')
	scripts/backup.sh $(FLAGS)

restore: ## scripts/restore.sh ARCHIVE=path/to/pi-tale-backup-*.tar.gz
ifndef ARCHIVE
	$(error usage: make restore ARCHIVE=path/to/pi-tale-backup-*.tar.gz)
endif
	scripts/restore.sh $(ARCHIVE)
