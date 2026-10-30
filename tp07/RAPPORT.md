# TP07 - Observabilité : logs, métriques, alertes

Fichiers : `compose.observability.yml`, `prometheus/prometheus.yml`, `prometheus/alerts.yml`, `promtail/config.yml`, `grafana/provisioning/` (datasources et dashboards), `grafana/dashboards/shop.json`, `load.sh`, et les captures dans `captures/`. Le fichier d'origine est dans `starter/`.

```bash
cd ../tp04 && docker compose -f compose.yml -f compose.prod.yml up -d --wait   # la stack du TP04 doit tourner (réseaux shop_front / shop_back)
cd ../tp07 && docker compose -f compose.observability.yml up -d
./load.sh 1000            # 1000 requêtes, 20 en parallèle par défaut
# http://localhost:9090/targets   http://localhost:3001 (admin / admin)
```

`load.sh` n'est pas fourni avec l'énoncé, je l'ai écrit : 80 % de `GET /products`, 20 % de `POST /orders`, dont une commande sur 10 avec `quantity: 150`, que le worker rejette. Il affiche le nombre de réponses par code HTTP.

J'ai utilisé la prod du TP04, pour avoir 2 réplicas de l'API. En la relançant, Traefik est passé `unhealthy` : il dépassait sa limite de 128 Mo et son healthcheck mettait 5 à 8 s. J'ai monté la limite à 256 Mo dans le TP04 (voir son rapport).

## 1. Les logs côté Docker

`jq` n'est pas installé sur mon poste, je l'ai lancé en conteneur (`docker run --rm -i ghcr.io/jqlang/jq:1.7.1`).

- `docker logs --since 5m --timestamps shop-api-1 | jq` ne marche pas : `--timestamps` ajoute la date devant chaque ligne (`2026-10-30T09:43:04.817Z {"level":30,...}`), ce qui n'est plus du JSON (`parse error: Invalid numeric literal`). Sans `--timestamps`, on lit bien `level`, `msg`, `req.url`, `res.statusCode`, `responseTime`. La date est déjà dans le champ `time` de pino.
- `LogConfig` : `{json-file map[max-file:3 max-size:10m]}`, la rotation du TP04.
- Sous Docker Desktop, il n'y a pas de `/var/lib/docker` sur Windows, et pas de `sudo`. Je suis passé par l'espace de noms de `dockerd` dans la VM (`docker run --privileged --pid=host alpine nsenter -t <pid de dockerd> -m ls ...`). Le dossier contient `<id>-json.log`, `config.v2.json`, `hostconfig.json`, `hosts`, `resolv.conf`... Chaque ligne du fichier est `{"log":"<ligne écrite par l'appli>\n","stream":"stdout","time":"..."}`. Il faisait 147 Ko au bout de 18 minutes, surtout à cause des appels `/health` de Traefik toutes les 10 s.
- `docker run --rm --log-driver none alpine echo "pas loggé"` affiche quand même le texte, parce qu'un `docker run` attaché reçoit la sortie directement. Mais rien n'est gardé : `docker logs` sur un conteneur lancé comme ça répond `configured logging driver does not support reading`.

Sans `max-size`, le fichier `json-file` grossit sans limite. Sur 6 mois, une appli bavarde remplit le disque de `/var/lib/docker`, et à ce moment-là ce sont tous les conteneurs (bases de données comprises) qui ne peuvent plus écrire. `docker logs` devient aussi très lent sur un fichier de plusieurs Go.

Un conteneur doit écrire sur stdout/stderr : Docker récupère ce flux et l'envoie au driver choisi, sans rien changer à l'appli. Un fichier de log dans le conteneur est perdu avec le conteneur, n'est pas visible avec `docker logs`, grossit dans la couche du conteneur sans rotation, et n'est pas collecté par Promtail.

| driver | où vont les logs | `docker logs` |
|---|---|---|
| `json-file` | fichier JSON sur l'hôte (défaut), rotation avec `max-size` / `max-file` | oui |
| `local` | fichier binaire compressé sur l'hôte, rotation activée par défaut, plus compact | oui |
| `journald` | journal systemd de l'hôte (`journalctl CONTAINER_NAME=...`) | oui |
| `fluentd` | envoyés à un démon fluentd / fluent-bit, qui les route ailleurs | oui depuis Docker 20.10, grâce à un cache local (« dual logging ») |
| `awslogs` | CloudWatch Logs | idem |

`mode: non-blocking` : les logs passent par un tampon en mémoire (`max-buffer-size`, 1 Mo par défaut) au lieu d'être écrits directement. Si le driver est lent ou injoignable (fluentd en panne, réseau vers CloudWatch), l'appli n'est pas bloquée sur ses écritures sur stdout. En contrepartie, quand le tampon est plein, les nouveaux logs sont perdus. En `blocking` (le défaut), on ne perd rien, mais l'appli peut se figer à cause de ses logs.

## 2. Métriques côté Docker

`docker stats` au repos : API 25 à 70 Mo, worker 40 Mo, base 46 Mo, Redis 8 Mo, Traefik 32 Mo. `docker system df` : 99 images (32,8 Go), 52 volumes (8,1 Go, dont `shop_pgdata` 73 Mo), 1,4 Go de cache de build.

API limitée à 64 Mo (`docker update --memory 64m --memory-swap 64m shop-api-1 shop-api-2`), puis `./load.sh 1500 40` :

```
HTTP 200 : 730   HTTP 201 : 181   HTTP 404 : 542   HTTP 502 : 47
/shop-api-1 OOMKilled=true restarts=0
/shop-api-2 OOMKilled=true restarts=1
```

`docker events --filter type=container --since 4m` montre une suite de `oom`, puis `die` / `start` pour `shop-api-2`, et `health_status: unhealthy` pour `shop-api-1`. Attention : avec `--since 2026-10-30T09:40:00`, l'heure est comprise comme une heure locale, pas UTC. J'avais passé une heure UTC et la commande ne renvoyait rien. Une durée (`--since 4m`) évite le problème.

Ce que j'ai trouvé en regardant les messages du noyau (`dmesg` dans la VM) : les processus tués sont des `node` de 35 Mo, pas le processus principal de l'API. C'est le `node -e fetch(...)` lancé par le healthcheck toutes les 10 s, qui ne trouve plus de place sous la limite. D'où `OOMKilled=true` alors que `shop-api-1` n'a jamais redémarré. Son healthcheck sort en 137, il passe `unhealthy`... et reste comme ça : Docker ne redémarre pas un conteneur `unhealthy`, seulement un conteneur qui s'arrête. Traefik ne route plus vers un conteneur `unhealthy`, d'où les 404 quand aucun réplica n'est sain, et les 502 quand le réplica meurt pendant une requête.

## 3. Stack d'observabilité

Prometheus rejoint `shop_front` et `shop_back` (déclarés `external`), plus le réseau du projet, où sont cAdvisor, Loki et Grafana.

Découverte de l'API par DNS : `dns_sd_configs` sur `api` renvoie une adresse par réplica, donc 2 cibles. J'ai vérifié que Prometheus, sur les deux réseaux, n'obtient pas 4 adresses : le DNS de Docker ne renvoie que celles d'un seul réseau. Quand un réplica est arrêté, il disparaît du DNS, donc des cibles. Il n'est pas `down`, il n'existe plus. C'est pour ça que `ApiDown` contient aussi `absent(up{job="api"})`, pour le cas où il n'y a plus aucun réplica.

Pourquoi pas `docker_sd_configs` : `docker exec observability-prometheus-1 id` donne `uid=65534(nobody)`, et la socket appartient à `root` avec les droits `rw-rw----`. Prometheus ne peut pas la lire. Il faudrait le lancer en root ou dans le groupe de la socket. Or un accès à la socket Docker revient à être root sur la machine (on peut lancer un conteneur `--privileged` qui monte `/`). Pour un service exposé sur le port 9090, ce n'est pas acceptable. Promtail, lui, a besoin de la socket pour lire les logs : c'est le seul conteneur à y avoir accès, et il n'expose aucun port.

cAdvisor sous Docker Desktop. Lancé normalement, il ne voit aucun conteneur : `failed to identify the read-write layer ID ... open /rootfs/var/lib/docker/image/overlayfs/layerdb/mounts/<id>/mount-id: no such file`. Docker Desktop range ses images avec containerd (`containerd-snapshotter=true` dans les logs de `dockerd`), et ce fichier n'existe pas dans ce mode. Les versions v0.52.1 et v0.53.0 font la même erreur. La solution : lire les conteneurs dans containerd (`--containerd`, espace de noms `moby`, socket `/run/containerd/containerd.sock` de la VM), et couper la partie Docker de cAdvisor en la faisant pointer vers une socket qui n'existe pas. Sinon, elle prend la main sur chaque conteneur et échoue. Les métriques arrivent alors, mais sans les labels Compose : un conteneur est identifié par son image et son ID. Dans le dashboard, je l'affiche comme `shopapi:1.4.3 7e3d7dd36170`. Sur un serveur Linux sans le stockage containerd, la configuration standard de cAdvisor fonctionne et donne les labels `container_label_com_docker_compose_service`.

Loki et Promtail. Promtail lit les logs de tous les conteneurs par l'API Docker (`docker_sd_configs`) et crée les labels `container`, `service` et `project` à partir des labels Compose, puis `level` à partir du JSON. Ce label vaut `30` / `50` pour l'API (pino) et `INFO` / `ERROR` pour le worker. Au premier démarrage, Loki refuse les logs de plus de 7 jours (`timestamp too old`), par exemple ceux de vieux conteneurs MySQL. C'est sans conséquence. Promtail est demandé par l'énoncé, mais Grafana l'a déprécié au profit de Grafana Alloy (fin de support annoncée pour mars 2026) : sur un nouveau projet, il faudrait utiliser Alloy.

Requêtes de l'énoncé :
- `{service="worker"} |= "rejected"` renvoie bien les commandes rejetées.
- `{service="api"} | json | level="50"` ne renvoie que les exceptions non gérées (`erreur non gérée`, par exemple `getaddrinfo ENOTFOUND db` ou `relation "orders" does not exist`). pino-http enregistre une réponse 5xx au niveau 30, avec `msg: "request errored"`. Une 503 de `/ready` n'apparaît donc pas avec cette requête. Le panneau d'erreurs du dashboard utilise `{project="shop"} | json | level=~"50|ERROR" or msg="request errored"`.
- `sum(rate(http_request_duration_seconds_count[1m])) by (status)` renvoie le débit par code HTTP.

Grafana. Les datasources (avec des `uid` fixes, référencés par le dashboard) et le dashboard sont chargés depuis des fichiers. Après un `down -v` puis un `up`, tout revient sans aucun clic. Le dashboard contient : réplicas `up`, requêtes/s, % de 5xx, p95, alertes en cours, débit par code, latence p50 / p95, commandes traitées par le worker, CPU et mémoire / limite par conteneur, redémarrages, alertes en cours, logs d'erreurs et commandes rejetées. Le mot de passe `admin/admin` est celui de l'énoncé : Grafana demande de le changer à la première connexion.

Alertes (`prometheus/alerts.yml`, vérifié avec `promtool check rules`). Chacune a été déclenchée pour de vrai :

| alerte | condition | panne qui l'a déclenchée |
|---|---|---|
| `ApiDown` | `up == 0` pendant 1 min, ou plus aucune cible | `docker pause shop-api-1` : le réplica reste dans le DNS mais ne répond plus (`context deadline exceeded`) |
| `ApiErreurs5xx` | plus de 5 % de 5xx sur 5 min, pendant 1 min | table `orders` renommée : 17,5 % de 500 sur `POST /orders` |
| `ApiLatenceP95` | p95 supérieur à 500 ms, pendant 1 min | Redis arrêté : `/ready` attend Redis, p95 à 9,5 s |
| `ConteneurRedemarre` | `container_start_time_seconds` a changé dans les 10 dernières minutes | redémarrage de Redis, OOMKill de l'API, et même mon redémarrage de Prometheus |
| `MemoireProcheLimite` | pic supérieur à 90 % de la limite sur 5 min, pendant 1 min | API limitée à 64 Mo |

Pour `MemoireProcheLimite`, ma première version (`working_set / limite > 0.9` pendant 1 min) ne s'est jamais déclenchée. La mémoire monte à 100 %, le processus est tué, elle retombe, et elle ne reste jamais une minute au-dessus de 90 %. L'alerte ratait précisément le cas qu'elle doit signaler. Elle regarde maintenant le maximum sur 5 minutes (`max_over_time(...[5m:15s])`).

## 4. Exercice de corrélation

J'ai injecté moi-même les pannes citées dans l'énoncé, pendant une charge continue (`load.sh`). Pour chacune, j'ai cherché la cause dans Grafana, puis je l'ai vérifiée avec `docker`.

| panne | ce que montre Grafana | vérification |
|---|---|---|
| Redis arrêté | le trafic chute à 0,2 req/s, p95 à 8 s, 503 sur `/ready`, plus aucune commande traitée ; logs du worker : `Error -3 connecting to redis:6379. Temporary failure in name resolution` | `docker compose ps` : `shop-redis-1 Exited (0)` |
| mot de passe BDD changé | rien pendant plusieurs minutes. Puis, après le redémarrage d'un réplica : alerte `ConteneurRedemarre`, `request errored` sur `/ready`, et dans les logs de `db` : `FATAL: password authentication failed for user "shop"` (16 fois en 5 min) | `docker inspect` : `shop-api-1 unhealthy`, `shop-api-2 healthy` |
| limite mémoire abaissée | pics à 100 % sur « Mémoire / limite », redémarrages en escalier, alertes `MemoireProcheLimite` et `ConteneurRedemarre` | `docker inspect --format '{{.State.OOMKilled}} {{.RestartCount}}'` : `true 1` pour `shop-api-1` ; `false 1` pour `shop-api-2`, car l'indicateur est remis à zéro quand le conteneur redémarre |
| table `orders` renommée | 19 % de 500, uniquement sur `POST /orders`, le worker ne traite plus rien ; logs : `relation "orders" does not exist` | `docker logs shop-db-1` : `ERROR: relation "orders" does not exist at character 13` (1 324 fois) |

La cause apparaît en moins d'une minute dans les logs, sauf pour le mot de passe. Les alertes, elles, mettent plus de temps : 2 à 4 minutes, à cause des fenêtres de 5 minutes et du `for: 1m`.

Ce que ces tests m'ont appris sur les limites de ce que j'ai mis en place :
- Le mot de passe changé ne se voit pas tout de suite : les connexions déjà ouvertes dans le pool de l'API restent valides. La panne n'apparaît qu'au redémarrage suivant, et seulement sur le réplica redémarré : l'autre continue à servir tout le trafic.
- Les pannes que l'API ne voit pas : quand la base ou Redis tombent, l'API passe `unhealthy` et c'est Traefik qui répond 404 aux utilisateurs. Ces erreurs n'arrivent jamais à l'API, donc pas dans ses métriques, et l'alerte 5xx ne se déclenche pas. Il faudrait aussi récupérer les métriques de Traefik.
- Le worker reste `healthy` sans Redis : son healthcheck ne vérifie que `/metrics`. La file n'est plus consommée sans qu'aucun état ne le signale, seulement le graphique des commandes traitées qui tombe à 0.
- L'API met du temps à revenir : après le retour de la base, il lui faut environ une minute pour redevenir `healthy`.

## Captures

- `dashboard-sous-charge.png` : le dashboard pendant `load.sh` (15,7 req/s, 2 réplicas, 0 % d'erreurs)
- `panne-redis-alertes.png` et `panne-redis-dashboard.png` : Redis arrêté (`ApiLatenceP95` en `firing`)
- `alertes-firing.png` : `ApiDown` et `ConteneurRedemarre` en `firing`, avec le détail
- `panne-memoire-dashboard.png` : limite mémoire abaissée et réplica en pause
- `alertes-firing-5xx.png` et `panne-table-dashboard.png` : table renommée (`ApiErreurs5xx` en `firing`)
