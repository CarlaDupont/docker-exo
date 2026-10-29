# TP04 - Stack Compose d'entreprise

Fichiers : `compose.yml` (base), `compose.override.yml` (dev, chargé automatiquement), `compose.prod.yml`, `compose.watch.yml` (dev sous Windows, voir étape 3), `.env.example`, `Makefile`, `smoke-test.sh`, `db/init.sql`, `db/migrations/002-add-sku.sql`. Le compose d'origine est gardé dans `docker-compose.starter.yml`.

L'API et le worker sont construits depuis `../tp01/shopapi` et `../tp02/shop-worker`. Le build du worker a besoin de `../tp02/shop-worker/pip.conf` (non versionné, voir le rapport du TP02).

```bash
make up                          # dev
make test
make migrate M=002-add-sku.sql
make tools                       # adminer sur http://adminer.localhost
make prod-up                     # prod
make test ENV=prod
```

## 1. Problèmes du compose d'origine

1. `version: '3'` : obsolète, ignoré par Compose v2 (il affiche un avertissement).
2. `links` : obsolète, les services se trouvent déjà par leur nom sur le réseau du projet.
3. images non épinglées (`postgres`, `redis` = `latest`) : un `pull` peut changer de version majeure sans prévenir.
4. ports 5432 et 6379 publiés : la base et Redis sont joignables depuis l'extérieur, et Redis n'a pas de mot de passe.
5. mot de passe `postgres` en clair, deux fois, dans un fichier versionné, et c'est l'utilisateur superadmin.
6. `sleep 10` avant de lancer l'API : trop long si la base est prête, trop court si elle ne l'est pas.
7. un seul réseau : l'API, le worker, la base et Redis sont tous au même niveau, sans séparation.
8. aucun healthcheck : impossible de savoir si un service est vraiment prêt, et `depends_on` ne sert à rien.
9. pas de volume nommé : les données de PostgreSQL sont dans un volume anonyme, facile à perdre.
10. `restart` incohérent : `always` sur le worker seulement, rien sur l'API ni sur la base.
11. pas de limites CPU ou mémoire, pas de rotation des logs.
12. pas de reverse proxy : l'API est exposée directement sur le port 3000.

## 2. Fichier de base

- `name: shop`, réseaux `front` (proxy, api) et `back` (`internal: true` : api, worker, db, redis)
- healthchecks partout, avec une ancre `x-healthcheck-defaults`. Celui de l'API appelle `/ready`, qui vérifie la base et Redis.
- `depends_on` avec `condition: service_healthy`, et `up --wait` ne rend la main qu'une fois tout healthy (74 s au premier lancement, build compris)
- `x-logging` (json-file, 3 fichiers de 10 Mo), `restart: unless-stopped`
- Traefik piloté par les labels de l'API, avec un healthcheck de backend sur `/health`
- profils `tools` (adminer) et `ops` (`migrate`)

`DATABASE_URL` sans modifier le code : l'API et le worker ont un `entrypoint` qui lit le secret et construit l'URL avant de lancer la commande avec `exec`.
```yaml
entrypoint:
  - /bin/sh
  - -c
  - export DATABASE_URL="postgres://shop:$$(cat /run/secrets/db_password)@db:5432/shop" && exec "$$@"
  - --
```
Grâce à `exec`, node reste le PID 1 et reçoit bien SIGTERM. Le mot de passe n'apparaît pas dans `docker inspect`. Il doit rester sans caractère spécial, puisqu'il est mis tel quel dans une URL : le `Makefile` le génère en hexadécimal. Attention avec l'`openssl` de Git Bash, qui ajoute un `\r` en fin de ligne : il faut faire `tr -d '\r\n'`, sinon le `\r` se retrouve dans l'URL.

Redis n'a toujours pas de mot de passe, mais il n'est que sur le réseau `back` (internal) et n'est joignable que par l'API et le worker. Pour en ajouter un, il faudrait aussi le mettre dans `REDIS_URL`, avec le même `entrypoint`.

Vérifié : `/ready` répond `db ok, redis ok`, `/products` passe de `X-Cache: MISS` à `HIT`, et une commande passe `confirmed` par le worker. La base et l'API ne répondent pas depuis l'hôte, et le worker n'a pas accès à Internet (`Temporary failure in name resolution`).

## 3. Surcharge dev

Ports 3000, 5432 et 8080 (tableau de bord Traefik), `LOG_LEVEL=debug`, code source monté, `node --watch`.

Deux problèmes rencontrés :
- un conteneur qui n'est que sur un réseau `internal` ne peut pas publier de port : `5432:5432` était ignoré, sans message d'erreur. En dev, le réseau `back` repasse donc en `internal: false`.
- sous Windows, `node --watch` ne voit pas les modifications faites dans le bind mount : le fichier change bien dans le conteneur, mais node ne redémarre pas. Et `develop.watch` refuse de surveiller un dossier qui est aussi monté en bind mount (`this path won't be monitored`). J'ai donc laissé le bind mount comme demandé dans `compose.override.yml`, et ajouté `compose.watch.yml`, qui retire le bind mount (`volumes: !reset []`) et utilise `sync+restart` (`make watch`). Avec ça, l'API redémarre bien après une modification de `server.js`.

## 4. Surcharge prod

- `build: !reset null` : supprime le `build` hérité du fichier de base
- images `${REGISTRY}/shopapi:${API_VERSION}` et `${REGISTRY}/shop-worker:${WORKER_VERSION}`. J'ai mis deux versions parce que l'API et le worker n'ont pas le même numéro. Sans `.env`, la commande s'arrête avec `REGISTRY manquant dans .env`.
- API en 2 réplicas, limites CPU et mémoire, `read_only` + `tmpfs`, `cap_drop: [ALL]`, `no-new-privileges` (API, worker, Traefik)
- pas de port de debug ni de tableau de bord (le port 8080 ne répond pas)

Registre : celui du TP03. Je n'ai pas configuré `registry.local` sur le poste, donc j'utilise `localhost:5000`, que Docker accepte sans installer la CA. Il faut un `docker login localhost:5000 -u ci` avant `make prod-up`.

Répartition de charge, d'après le champ `ServiceAddr` des logs d'accès de Traefik, sur 10 requêtes : 5 vers `192.168.144.3` et 5 vers `192.168.144.4`, les deux réplicas.

`up -d --scale api=3` crée un troisième conteneur. Un `up -d` normal le supprime ensuite et revient à 2 : c'est `deploy.replicas` du fichier qui fait foi.

## 5. Makefile et smoke test

Toutes les cibles prennent `ENV=prod` pour utiliser `compose.yml` + `compose.prod.yml`. C'est nécessaire : au début, `make migrate` utilisait la configuration de dev alors que la prod tournait. Compose a recréé la base de prod avec la config de dev, ce qui a supprimé sa limite mémoire et ajouté le port 5432, le tout sans erreur. Maintenant la migration utilise le bon environnement, avec `--no-deps` pour ne jamais toucher aux autres services.

`smoke-test.sh` vérifie, en passant par Traefik : `/ready`, `/products` servi depuis Redis, la création d'une commande, et son passage à `confirmed` par le worker (statut lu dans la base). Il attend jusqu'à 30 s que `/ready` réponde, car Traefik met une ou deux secondes à router vers un conteneur qui vient de passer healthy. Si on arrête le worker, le test échoue bien (`statut de la commande : pending`).

`make` n'est pas installé sur mon poste Windows : j'ai testé le `Makefile` dans un conteneur Linux (`docker:27.3.1-cli` + make), sur deux cycles complets up / test / migrate / tools / down, et en prod.
