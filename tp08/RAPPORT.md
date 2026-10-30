# TP08 - Durcir les conteneurs pour la production

Fichiers : `audit.sh`, `compose.hardened.yml` (surcharge de la stack du TP04), `daemon.json` (proposition), `audit-avant.txt` / `audit-apres.txt`, `seccomp-default.json` (profil seccomp par défaut de Moby 27.3.1, utilisé pour l'expérience seccomp).

```bash
cd ../tp04
docker compose -f compose.yml -f ../tp08/compose.hardened.yml up -d --wait
COMPOSE="docker compose -f compose.yml -f ../tp08/compose.hardened.yml" ./smoke-test.sh
../tp08/audit.sh shop
```

La surcharge marche aussi par-dessus la prod du TP04 (`-f compose.yml -f compose.prod.yml -f ../tp08/compose.hardened.yml`), testée avec le smoke test.

## 1. Mesurer

`audit.sh [projet]` lit `docker inspect` de chaque conteneur en cours d'exécution (ou seulement ceux d'un projet Compose) et affiche : utilisateur, `Privileged`, capabilities ajoutées / retirées, rootfs en lecture seule, limite mémoire, `PidsLimit`, `no-new-privileges`, socket Docker montée. Le code retour vaut 1 s'il y a un écart. Il compte comme écart une capability dangereuse ajoutée (`SYS_ADMIN`, `NET_ADMIN`, `SYS_PTRACE`...), mais pas une capability ajoutée et justifiée. Je l'ai vérifié sur un conteneur volontairement mauvais (`--privileged --cap-add SYS_ADMIN`, socket montée : 9 écarts, code 1) et sur un conteneur durci (0 écart, code 0).

| stack du TP04 | écarts |
|---|---|
| `compose.yml` seul | 29 (`audit-avant.txt`) |
| `compose.yml` + `compose.prod.yml` | 16 |
| `compose.yml` + `compose.hardened.yml` | 1 : la socket du proxy de socket, qui est voulue (`audit-apres.txt`) |

docker-bench-security, avec la commande de l'énoncé : `Checks: 105`, `Score: -1`, 248 lignes WARN. L'image `docker/docker-bench-security` date de janvier 2019 (v1.3.4) et n'a jamais été mise à jour, alors que le script continue d'évoluer sur GitHub. Le bench regarde toute la machine : une bonne partie des WARN vient d'autres conteneurs (MySQL des exercices, registre, builder BuildKit en `--privileged`), et les sections 1 et 2 parlent de la VM de Docker Desktop, pas de mon poste.

Les 5 WARN prioritaires pour la stack :
1. `5.31` socket Docker montée dans Traefik : quiconque contrôle Traefik contrôle Docker, donc la machine
2. `4.1` conteneurs en root : PostgreSQL, Redis, Traefik
3. `5.10` aucune limite mémoire : un service qui fuit fait tomber les autres
4. `5.25` pas de `no-new-privileges` : un binaire setuid peut redonner root
5. `5.12` rootfs en écriture : un attaquant peut modifier les binaires ou déposer ses outils

Après durcissement, les lignes WARN qui citent un conteneur de la stack passent de 46 (pour 5 conteneurs) à 22 (pour 6, avec le proxy de socket). Il n'en reste plus aucune sur l'utilisateur, la mémoire, les PIDs, la lecture seule ou `no-new-privileges`. Ce qui reste : AppArmor (absent de la VM Docker Desktop), la priorité CPU, la politique `on-failure:5`, le port 80 publié sur toutes les interfaces (choix du TP04), et la socket du proxy.

## 2. Comprendre chaque mesure

Toutes les expériences sont faites sur `alpine:3.20.3`, sauf la mémoire (`python:3.12-alpine`).

| mesure | expérience | résultat |
|---|---|---|
| `--read-only` | `touch /x`, puis `--tmpfs /tmp` et `touch /tmp/x` | `Read-only file system`, puis OK dans `/tmp` |
| `--cap-drop ALL` | `ping 1.1.1.1` | marche quand même : Docker règle `net.ipv4.ping_group_range` sur `0 2147483647`, donc ping n'a pas besoin de socket brute. Avec `--sysctl net.ipv4.ping_group_range="1 0"` : `permission denied`, et il faut `NET_RAW` |
| | `chown 1000 /f` | `Operation not permitted`, il faut `CHOWN` |
| | `apk add` | `curl` s'installe (fichiers à root). `redis` échoue (`Failed to set ownership`) : il crée un utilisateur et change des propriétaires. Minimum trouvé : `CHOWN` + `FOWNER`. Installer des paquets est un travail de build, pas d'exécution : en prod, on ne rajoute rien |
| `no-new-privileges` | `/bin/busybox` n'est pas setuid, et `passwd` est une commande busybox. J'ai pris `sudo` (`-rwsr-xr-x`), lancé par `nobody` avec une règle `NOPASSWD` | sans l'option : `sudo id -u` donne `0`. Avec : `The "no new privileges" flag is set, which prevents sudo from running as root` |
| `--pids-limit 50` | 100 `sleep` en arrière-plan | `can't fork: Resource temporarily unavailable`, 49 processus (`docker stats`) contre 101 sans limite. Le shell s'arrête au premier fork refusé : j'ai lancé la boucle dans un sous-shell pour garder le conteneur |
| `--memory 32m` | `python -c "x='a'*100_000_000"` | code 137, `OOMKilled=true` |
| `--user 1000` | `id` | `uid=1000 gid=0(root)` : sans groupe précisé, on reste dans le groupe root. Mieux vaut `--user 1000:1000` |
| | volume nommé neuf monté dans `/data` | le dossier appartient à root : `touch /data/x` donne `Permission denied`. Il faut que l'image crée le dossier avec le bon propriétaire avant la première utilisation du volume, ou faire un `chown` |
| seccomp | `unshare --user id` avec et sans `--security-opt seccomp=unconfined` | aucune différence sur mon poste. Docker Desktop lance `dockerd` avec `"seccomp-profile":"unconfined"` (lu dans `/run/config/docker/daemon.json` de la VM). Les conteneurs ne reçoivent pas le profil par défaut, seulement le filtre sous lequel tourne `dockerd` lui-même. En passant le profil officiel (`--security-opt seccomp=seccomp-default.json`) : `unshare(0x10000000): Operation not permitted` |

Combien d'appels système bloque le profil par défaut : sur les 385 appels x86_64 des en-têtes du noyau, il en autorise 298, en tenant compte des capabilities données par défaut à un conteneur. `clone`, `personality` et `socket` ne sont autorisés qu'avec certains arguments, et 84 sont bloqués. Parmi eux : `mount`, `umount2`, `unshare`, `setns`, `pivot_root`, `bpf`, `perf_event_open`, `kexec_load`, `init_module`, `reboot`, `keyctl`, `userfaultfd`, `io_uring_*`, `open_by_handle_at`... Une quinzaine sont simplement trop récents pour ce profil (`listmount`, `statmount`, `mseal`, `lsm_*`...) : ils sont refusés par l'action par défaut (`SCMP_ACT_ERRNO`).

## 3. Durcir la stack

`compose.hardened.yml` applique à tous les services : `read_only`, `cap_drop: [ALL]`, `no-new-privileges`, limites CPU, mémoire et PIDs. Chaque directive est commentée avec la menace qu'elle réduit.

| service | utilisateur | capabilities ajoutées | tmpfs |
|---|---|---|---|
| api | node (image) | aucune | `/tmp` |
| worker | worker (image) | aucune | `/tmp` |
| db | postgres | aucune | `/tmp`, `/var/run/postgresql` |
| redis | redis | aucune | `/tmp` |
| proxy (Traefik) | 65534:65534 | aucune | - |
| socket-proxy | 65534:0 | aucune | `/tmp`, `/run` |

PostgreSQL. En root avec `cap_drop: [ALL]`, j'ai cherché par essai/erreur sur un volume neuf, puis au redémarrage :

| capabilities | volume neuf | redémarrage |
|---|---|---|
| aucune / `CHOWN` | échec : `failed switching to "postgres": operation not permitted` (il faut `SETUID` / `SETGID`) | - |
| `CHOWN SETUID SETGID` | OK | échec : `find: /var/lib/postgresql/data: Permission denied` |
| `CHOWN SETUID SETGID FOWNER` | échec : `find: ... Permission denied` | - |
| `CHOWN SETUID SETGID DAC_OVERRIDE` | OK | OK |

Ces résultats s'expliquent par le script d'entrée. Il fait `chmod 700` sur le dossier de données, en ignorant l'erreur, puis un `find` dedans. Une fois le dossier en 700 et propriété de `postgres`, root ne peut plus le lire sans `DAC_OVERRIDE`. Le piège : `CHOWN SETUID SETGID` passe sur une base neuve et casse au premier redémarrage. Il faut donc 4 capabilities en root. J'ai préféré lancer directement en `user: postgres` : le script n'a plus de `chown` ni de `gosu` à faire, et il ne faut aucune capability. Testé sur volume neuf, au redémarrage, et sur le volume existant du TP04.

Traefik. On attend `NET_BIND_SERVICE` pour le port 80, mais il n'en a pas besoin, même en `nobody` : Docker règle `net.ipv4.ip_unprivileged_port_start=0` dans chaque conteneur. Avec `--sysctl net.ipv4.ip_unprivileged_port_start=1024`, Traefik échoue sans `NET_BIND_SERVICE` et repart avec.

Redis. En `user: redis`, le script d'entrée ne fait plus le `chown` de `/data`. Le volume du TP04 appartient déjà à `redis` : rien à changer.

Socket Docker. Traefik n'a plus de volume (`volumes: !reset []`). Il parle à `tecnativa/docker-socket-proxy:v0.5.0` (`TRAEFIK_PROVIDERS_DOCKER_ENDPOINT=tcp://socket-proxy:2375`) sur un réseau `socket` en `internal`. Le proxy n'autorise que des lectures (`POST=0` par défaut) et les routes utiles (`CONTAINERS=1`, plus `VERSION`, `PING` et `EVENTS` par défaut). Depuis le conteneur Traefik : `GET /containers/json` est autorisé, `POST /containers/create` et `GET /images/json` donnent `403 Forbidden`, et `/var/run/docker.sock` n'existe plus. Le proxy tourne en `nobody` dans le groupe 0, qui suffit pour ouvrir la socket (`root:root`, droits 660).

Monter la socket en `:ro` ne protège rien : un conteneur avec la socket en `:ro` crée sans problème un conteneur (`docker create` testé). `:ro` empêche de modifier le fichier, pas d'envoyer des requêtes à l'API. C'est le proxy qui filtre.

Problèmes rencontrés :
- Compose refuse `pids_limit` à côté de `deploy.resources.limits` (`can't set distinct values on 'pids_limit' and 'deploy.resources.limits.pids'`) : la limite est dans `deploy.resources.limits.pids`.
- Par-dessus `compose.prod.yml`, la liste `security_opt` était concaténée et `no-new-privileges:true` apparaissait deux fois, ce que Compose refuse. `security_opt: !override` remplace la liste au lieu de la compléter.
- Un tmpfs prend les droits du dossier de l'image, mais appartient à root. `/run` (755) n'était pas accessible en écriture pour le proxy (`Cannot create pidfile /run/haproxy.pid`), et le `chmod` de `/var/run/postgresql` échouait (sans conséquence, l'erreur est ignorée). J'ai donné ces tmpfs à leur utilisateur (`/run:uid=65534`, `/var/run/postgresql:uid=70,gid=70`).

Validation : `up -d --wait` OK, smoke test du TP04 vert (`/ready`, cache `HIT`, commande créée et confirmée par le worker), aucun message `Permission denied` ou `Read-only file system` dans les logs. Traefik suit une API recréée (événements via le proxy), et la stack repart après un `down` / `up` complet. `audit.sh` : plus aucun écart sur les services applicatifs.

## 4. Côté daemon

`daemon.json` proposé. Je ne l'ai pas appliqué : sur Docker Desktop, la configuration du démon appartient à Docker Desktop, et j'ai choisi de ne pas la modifier. Je l'ai validé avec `dockerd --validate` (Docker 27.3.1, en conteneur) : `configuration OK`. La même commande refuse bien une faute de frappe (`no-new-privilege`).

| directive | pourquoi |
|---|---|
| `"icc": false` | sur le bridge par défaut, les conteneurs ne se parlent plus entre eux |
| `"no-new-privileges": true` | appliqué à tous les conteneurs, même ceux lancés à la main sans l'option |
| `"live-restore": true` | les conteneurs continuent de tourner pendant un redémarrage ou une mise à jour de `dockerd` (incompatible avec Swarm) |
| `"userland-proxy": false` | les ports publiés passent par iptables au lieu d'un processus `docker-proxy` par port (Docker Desktop l'a déjà) |
| `log-driver` / `log-opts` | rotation par défaut pour tous les conteneurs, y compris ceux qui ne la précisent pas (TP07) |
| `"userns-remap": "default"` | root dans un conteneur devient un utilisateur sans droits sur l'hôte (plage de `dockremap`), ce qui limite les dégâts d'une évasion |

Effet de `icc: false` sur la stack : aucun. L'option ne concerne que le bridge par défaut (`docker0`). Les réseaux Compose (`shop_front`, `shop_back`) gardent leur propre réglage, à `true` par défaut. Je l'ai vérifié avec un réseau créé avec `-o com.docker.network.bridge.enable_icc=false` : deux conteneurs de ce réseau ne se joignent plus (`download timed out`), alors qu'Internet reste accessible. Sur un réseau normal, ça marche. Un conteneur lancé avec un simple `docker run`, sans réseau, ne pourrait plus parler aux autres conteneurs du bridge par défaut.

Effet de `userns-remap` sur l'existant (non testé, pour la même raison) : Docker utilise un autre dossier de stockage (`/var/lib/docker/<uid>.<gid>/`). Images, conteneurs et volumes existants ne sont plus visibles : il faut retirer les images et migrer les volumes. Dans un volume, les fichiers gardent leur propriétaire numérique de l'hôte. Les fichiers de `shop_pgdata` appartiennent à l'uid 70, qui correspond dans le conteneur à un utilisateur qui n'existe pas (affiché `nobody`), et PostgreSQL ne pourrait plus lire sa base. Il faut décaler les propriétaires (70 devient 100070 si la plage commence à 100000), ou restaurer depuis un dump (TP05). `--privileged`, `--pid host` et `--network host` demandent alors `--userns=host`. L'autre option est Docker rootless : tout le démon tourne sans root, avec des limites sur les ports en dessous de 1024 et sur certaines fonctions réseau.
