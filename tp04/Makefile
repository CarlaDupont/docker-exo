# make <cible>            -> environnement de dev (compose.yml + compose.override.yml)
# make <cible> ENV=prod   -> prod (compose.yml + compose.prod.yml)
ENV ?= dev
ifeq ($(ENV),prod)
COMPOSE = docker compose -f compose.yml -f compose.prod.yml
else
COMPOSE = docker compose
endif

.PHONY: up down watch logs ps tools migrate test prod-up prod-down

secrets/db_password.txt:
	openssl rand -hex 16 | tr -d '\r\n' > $@

up: secrets/db_password.txt
	$(COMPOSE) up -d --wait $(if $(filter dev,$(ENV)),--build)
	$(COMPOSE) ps

down:
	$(COMPOSE) down

ps:
	$(COMPOSE) ps

logs:
	$(COMPOSE) logs -f --tail=50

# Windows : rechargement du code avec compose watch au lieu de node --watch
watch: secrets/db_password.txt
	docker compose -f compose.yml -f compose.override.yml -f compose.watch.yml watch

tools:
	$(COMPOSE) --profile tools up -d --wait adminer

# --no-deps : la migration ne doit pas recréer la base ou l'api
migrate:
	$(if $(M),,$(error usage : make migrate M=002-add-sku.sql [ENV=prod]))
	MIGRATION=$(M) $(COMPOSE) --profile ops run --rm --no-deps migrate

test:
	COMPOSE="$(COMPOSE)" ./smoke-test.sh

prod-up:
	$(MAKE) up ENV=prod

prod-down:
	$(MAKE) down ENV=prod
