# Rapport d'incident — préprod Shop SAS

**Heure de début** : 12:12 · **Heure de résolution** : 12:22 · **Impact** : préprod indisponible (port 8081 sans réponse, puis 502, puis 500)

## Chronologie du diagnostic

| Heure | Symptôme observé | Commande / preuve | Hypothèse | Résultat |
|-------|------------------|-------------------|-----------|----------|
| 12:12 | `docker compose up` ne démarre rien | `docker compose config -q` : `can't set container_name and api as container name must be unique` | `container_name` fixe incompatible avec 2 réplicas | confirmé, `container_name` retiré |
| 12:13 | `curl localhost:8081` sans réponse, `front` reste `Created` | sortie de `up` : `error mounting ".../nginx" to rootfs at "/etc/nginx/conf.d/default.conf" ... not a directory` | un dossier est monté à la place d'un fichier | confirmé, on monte `./nginx/default.conf` |
| 12:13 | les 2 `api` en `Exited (1)` | `docker compose logs api` : `Cannot find module '/app/server.js'` ; `ls /app` : le fichier est dans `src/` ; `docker image inspect` : `CMD ["node","src/server.js"]` | `command` du compose remplace la bonne commande de l'image | confirmé, `command` supprimé |
| 12:14 | tout tourne mais curl : `connection refused` (code 7), colonne PORTS vide pour `front` | `docker inspect front` : `PortBindings` 8081 demandé, `Ports` vide ; `docker network inspect incident_public` : `internal=true` | Docker ne publie pas de port sur un réseau interne | confirmé : `public` passe en normal, `backend` en `internal` |
| 12:14 | `up -d` ne change rien, les réseaux gardent l'ancien `internal` | `docker network inspect` après `up -d` | Compose ne recrée pas un réseau existant | confirmé, `down` (sans `-v`) puis `up` |
| 12:15 | `/health` répond `front ok`, `/products` en 502 | log nginx : `connect() failed (111) ... upstream: "http://127.0.0.1:3000/products"` | `localhost` dans nginx = le conteneur nginx lui-même | confirmé, `proxy_pass http://api:3000` |
| 12:15 | l'API écoute sur 8080, son healthcheck échoue | netshoot `--network container:incident-api-1` : `ss -tlnp` montre `*:8080` ; `.State.Health` : `ExitCode 1` à chaque essai | `PORT: 8080` alors que l'image (EXPOSE, healthcheck) est faite pour 3000 | confirmé, `PORT` supprimé |
| 12:16 | `/products` en 500 après 3,8 s, `/ready` : `ENOTFOUND databse` | `docker exec api getent hosts databse / db / redis` : aucun résolu ; `docker inspect` : api sur `public` seulement, redis en `NetworkMode=host` | faute de frappe + api pas sur `backend` + redis hors du réseau du projet | confirmé, 3 corrections |
| 12:17 | `/ready` : `db ok`, `NOAUTH Authentication required` | log api : `ReplyError: NOAUTH` ; redis lancé avec `--requirepass` | mot de passe absent de `REDIS_URL` | confirmé, catalogue OK, `X-Cache: MISS` puis `HIT` |
| 12:18 | `front` et `redis` sans état de santé ; log db plein de `FATAL` | `docker inspect ... .State.Health` : aucun ; `docker logs db \| grep -c 'role "postgres"'` : 39 ; `pg_isready -U nimportequi` répond OK quand même | healthchecks manquants, et celui de db utilise un rôle qui n'existe pas | confirmé, healthchecks ajoutés, plus aucun `FATAL` |
| 12:20 | mots de passe déplacés dans `.env` : tout est `healthy` mais `/ready` : `password authentication failed` | log db : `FATAL: password authentication failed for user "shop"` | `POSTGRES_PASSWORD` n'est lu qu'à l'initialisation du volume ; et le healthcheck de l'API (`/health`) ne vérifie rien | confirmé : `ALTER USER`, healthcheck de l'API sur `/ready` |
| 12:21 | test : API lancée avec un faux mot de passe | `POSTGRES_PASSWORD=faux docker compose up -d --wait` : `container incident-api-1 is unhealthy`, code 1 | le nouveau healthcheck détecte la panne | confirmé |
| 12:22 | validation depuis un volume vide | `down -v`, `up -d --wait` (21 s), 5 services `healthy`, `/products` `MISS` puis `HIT`, 5432/6379/3000 fermés depuis l'hôte | | résolu |

## Anomalies trouvées

| # | Fichier / service | Anomalie | Correction | Catégorie |
|---|-------------------|----------|------------|----------|
| 1 | compose / api | `container_name: api` avec `replicas: 2` : le projet est refusé | `container_name` retiré | config |
| 2 | compose / front | dossier `./nginx` monté sur le fichier `default.conf` : le conteneur ne démarre pas | `./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro` | stockage |
| 3 | compose / api | `command: node server.js` : le fichier est dans `src/`, crash au démarrage | `command` retiré, on garde le CMD de l'image | config |
| 4 | compose / réseaux | `public` en `internal: true` (port 8081 jamais publié, sans erreur) et `backend` ouvert | `public` normal, `backend` en `internal: true` | réseau |
| 5 | default.conf | `proxy_pass http://localhost:3000` vise nginx lui-même | `proxy_pass http://api:3000` | réseau |
| 6 | compose / api | `PORT: 8080` : l'API n'écoute plus sur 3000, son healthcheck échoue | `PORT` retiré | config |
| 7 | compose / api | `databse` dans `DATABASE_URL` | `db` | config |
| 8 | compose / api | api uniquement sur `public`, ne voit ni db ni redis | api sur `public` et `backend` | réseau |
| 9 | compose / redis | `network_mode: host` : pas de nom DNS dans le projet, et redis écoute sur `0.0.0.0:6379` de la machine | réseau `backend` | réseau / sécurité |
| 10 | compose / api | `REDIS_URL` sans le mot de passe demandé par `--requirepass` | `redis://:mot_de_passe@redis:6379` | config |
| 11 | compose / db | `pg_isready -U postgres` : le rôle n'existe pas, un `FATAL` toutes les 5 s dans les logs | `pg_isready -U shop -d shop` | config |
| 12 | compose / front, redis | pas de healthcheck : impossible d'avoir une stack `healthy` ni d'attendre avec `--wait` | healthchecks ajoutés (`127.0.0.1` pour nginx : `localhost` donne `::1` et nginx n'écoute qu'en IPv4) | cycle de vie |
| 13 | compose / front, api | `front` dépend de `api` sans condition, `api` ne dépend pas de `redis` | `condition: service_healthy` partout | cycle de vie |
| 14 | compose / api | healthcheck de l'image sur `/health` : `healthy` même sans base ni redis | healthcheck surchargé dans le compose sur `/ready` (l'image n'est pas modifiée) | cycle de vie |
| 15 | compose | mots de passe en clair dans un fichier versionné (`shop`, `r3dis`) | `.env` non versionné, `${VAR:?}`, et nouveaux mots de passe puisque les anciens sont dans l'historique Git | sécurité |

## Pourquoi ça n'a pas été détecté avant ?

- Personne n'a lancé `docker compose config` : l'anomalie 1 bloque tout dès cette commande.
- Pas de `up --wait` ni de smoke test après la modification. Le compose a été poussé sans avoir été démarré.
- Plusieurs erreurs ne donnent aucun message : port non publié sur un réseau interne, réseau pas recréé, `pg_isready` qui répond OK avec un mauvais rôle.
- Les healthchecks ne vérifiaient pas l'essentiel : l'API était `healthy` sans pouvoir parler à la base.
- Changement fait seul, sans relecture, juste avant un départ en congé.

## Actions de prévention

1. En CI, à chaque modification du compose ou de la conf nginx : `docker compose config -q`, puis `docker compose up -d --wait`, puis un smoke test (`/ready`, `/products` deux fois avec `X-Cache: HIT`). Le merge est bloqué si une étape échoue.
2. Des healthchecks qui testent les dépendances (`/ready` et pas `/health`) avec `depends_on: condition: service_healthy`, et le déploiement de la préprod fait avec `up --wait` : une stack cassée échoue au lieu de s'afficher « Up ».
3. Relecture obligatoire (merge request) pour le compose et la conf nginx, et le déploiement se fait depuis un commit taggé : en cas de problème, on redéploie le tag précédent au lieu de corriger à la main.
