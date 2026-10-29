# TP05 - Données : persistance, sauvegarde, restauration, montée de version

Fichiers : `backup.sh`, `restore.sh`, `upgrade-pg.sh`, `checksum.sql`, `compose.backup.yml` (sidecar pour la stack du TP04), `legacy/` (base PostgreSQL 14 du starter + `compose.pg16.yml`), `seed.sh` (starter, inchangé). Les transcripts sont dans `transcripts/`.

`checksum.sql` reprend le calcul de `seed.sh` (id + status des commandes) et ajoute un checksum sur toutes les colonnes de `orders` et `products`. Celui de `seed.sh` ne verrait pas une perte des quantités ou des prix.

## 1. Anatomie du stockage

Montages de la base du TP04 (`docker inspect ... --format '{{json .Mounts}}'`) :
```
bind    tp04\db\init.sql                         -> /docker-entrypoint-initdb.d/01-init.sql  (lecture seule)
volume  shop_pgdata (/var/lib/docker/volumes/shop_pgdata/_data) -> /var/lib/postgresql/data
bind    tp04/secrets/db_password.txt             -> /run/secrets/db_password  (lecture seule)
```
`shop_pgdata` fait 48 Mo (`docker system df -v`), avec le driver `local`.

**Couche du conteneur ou volume.** J'ai fait `touch /tmp/x`, puis écrit 10 000 lignes en SQL. `docker diff` montre `A /tmp/x`, mais rien sous `/var/lib/postgresql/data` : ce qui est écrit dans le volume ne passe pas par la couche overlay du conteneur. La couche disparaît avec le conteneur, le volume reste.

**Ce que deviennent les données**, testé sur une copie (projet `shopcopie`) avec une table témoin :

| commande | volume | données |
|---|---|---|
| `docker compose down` | gardé | gardées |
| `docker compose rm` | gardé | gardées |
| `docker volume prune` | gardé | gardées |
| `docker volume prune --all` | supprimé | perdues |
| `docker compose down -v` | supprimé | perdues |

Depuis Docker 23, `docker volume prune` ne supprime que les volumes anonymes : il faut `--all` pour les volumes nommés. Attention aussi, `prune` agit sur toute la machine et pas seulement sur le projet. Je l'ai toujours lancé avec `--filter label=com.docker.compose.project=shopcopie`.

**Volume anonyme.** `docker run -d postgres:16.4-alpine` sans `-v` crée quand même un volume au nom aléatoire (`cfff3da7...`), parce que l'image déclare `VOLUME /var/lib/postgresql/data`. Après `docker rm`, il reste orphelin. Il faut `docker rm -v` pour le supprimer. C'est un piège parce qu'on croit que la base est jetée avec le conteneur, alors que les volumes orphelins s'accumulent sans nom pour les retrouver (il y en avait déjà 7 sur mon poste, venant d'autres projets). Et si on relance un nouveau conteneur, il ne réutilise pas l'ancien volume : on croit avoir perdu les données alors qu'elles sont toujours là.

**Bind mount, volume nommé, tmpfs.** Écriture de 2 000 petits fichiers sur Docker Desktop Windows :

| | essai 1 | essai 2 |
|---|---|---|
| bind mount (dossier Windows) | 6,91 s | 7,59 s |
| volume nommé | 0,13 s | 0,10 s |
| tmpfs | 0,05 s | 0,07 s |
| couche du conteneur | 0,25 s | 0,19 s |

Le bind mount passe par le partage de fichiers entre Windows et la VM Docker, d'où un facteur 60. Je l'utilise pour le code en dev (on veut modifier les fichiers depuis l'éditeur) et pour des fichiers de config en lecture seule. Le volume nommé sert pour les données (base, Redis), et le tmpfs pour les fichiers temporaires qu'on ne veut pas garder, ni sur disque ni dans l'image (`/tmp` en lecture seule au TP04).

**init.sql n'est pas rejoué.** Le script d'entrée de l'image ne lance `/docker-entrypoint-initdb.d` que si le dossier de données est vide. Au redémarrage, on lit dans les logs `Database directory appears to contain a database; Skipping initialization`. Pour réinitialiser, il faut repartir d'un volume vide (`down -v`, ou supprimer le volume) : on perd alors les données, d'où l'intérêt de sauvegarder avant.

## 2. Sauvegarde et restauration

`backup.sh [logique|brute|tout]` :
- `pg_dump -Fc` lancé dans le conteneur de la base, puis vérifié avec `pg_restore --list`
- copie brute du volume avec `alpine` et `tar`, montage en `:ro`
- les 7 dernières sauvegardes de chaque type sont gardées (testé avec `KEEP=3` : 5 sauvegardes, il en reste 3)

La copie brute est incohérente si la base tourne pendant le `tar` : les fichiers sont copiés à des moments différents, alors que PostgreSQL écrit en continu (données, WAL). On peut récupérer une base qui ne démarre pas, ou des données à moitié écrites. Il y a deux solutions : arrêter la base pendant la copie, ce que fait `backup.sh`, ou, sans arrêt, `pg_backup_start()` / `pg_backup_stop()` en copiant aussi les WAL générés pendant la copie (c'est ce que fait `pg_basebackup`).

`restore.sh FICHIER` : `pg_restore --clean --if-exists --single-transaction` pour un `.dump` (tout ou rien), ou remplacement du contenu du volume pour un `.tar.gz`, puis affichage du checksum.

Preuve complète dans `transcripts/restauration.txt`, sur la stack du TP04 :
```
seed                    commandes=100000 checksum=8e2c3007e8f32687ae06c58e43b9b7e4
                        checksum_complet=17fca45bb6e2acf27a62ee343b822b4c
down -v puis up         commandes=0 checksum=vide
restore du .dump        commandes=100000 checksum=8e2c3007e8f32687ae06c58e43b9b7e4  -> identique
down -v puis up         commandes=0 checksum=vide
restore du .tar.gz      commandes=100000 checksum=8e2c3007e8f32687ae06c58e43b9b7e4  -> identique
```

Sidecar : `docker compose -f ../tp04/compose.yml -f compose.backup.yml up -d`, avec `BACKUP_SCHEDULE="@every 1m"` pour le test. Un dump par minute apparaît dans `/backups/last`, plus les rotations daily, weekly et monthly. J'ai vérifié le dernier : `gzip -t` passe et il contient les 100 000 commandes. Les dumps vont dans un volume nommé (`pgbackups`), parce que ce fichier est ajouté à la stack du TP04 : un chemin relatif y serait résolu depuis `../tp04`, et non depuis `tp05`.

## 3. Montée de version PostgreSQL 14 -> 16

Changer seulement le tag ne marche pas :
```
FATAL:  database files are incompatible with server
DETAIL:  The data directory was initialized by PostgreSQL version 14, which is not compatible with this version 16.4.
```
Le format des fichiers de données change entre deux versions majeures. Il faut passer par un dump et une restauration, ou par `pg_upgrade`. PG16 refuse de démarrer sans toucher aux fichiers, donc ce test ne casse rien.

`upgrade-pg.sh` : checksum avant, `pg_dumpall` + `pg_dump -Fc`, arrêt de PG14, PG16 sur un nouveau volume (`compose.pg16.yml` avec `volumes: !override`), `pg_restore`, checksum après, verdict. Le script refuse de tourner si le volume PG16 existe déjà.

Résultat (`transcripts/montee-de-version.txt`) :
```
avant  PostgreSQL 14.13   commandes=100000 checksum=61ed1a23a31f1bb9d34a3b69e3e8b203  complet=187d7cb8d24013cb3aed2179f4b466e4
après  PostgreSQL 16.4    commandes=100000 checksum=61ed1a23a31f1bb9d34a3b69e3e8b203  complet=187d7cb8d24013cb3aed2179f4b466e4
VERDICT : OK, données identiques
```

Retour arrière : `docker compose -f compose.yml up -d` dans `legacy/` relance PG14 sur l'ancien volume, qui n'a pas été modifié. Testé : mêmes checksums en 14.13, puis retour en 16.4. On ne supprime `shopdata_pgdata` qu'une fois la nouvelle version validée en production. Attention : `docker compose -f compose.yml -f compose.pg16.yml down -v` ne supprime que le volume PG16, puisque `!override` remplace la liste des volumes. Je m'en suis rendu compte en refaisant le test : l'ancienne base était restée, et le seed était passé à 200 000 commandes.

`pg_dump` sauvegarde une seule base, et en format custom (`-Fc`) on peut restaurer en parallèle ou seulement certaines tables. `pg_dumpall` sauvegarde tout le serveur en SQL, y compris ce qui n'appartient à aucune base (rôles, mots de passe, tablespaces). Ici je restaure avec le `pg_dump`. Le `pg_dumpall` est gardé pour les rôles, et comme sauvegarde de secours lisible.

Pourquoi un nouveau volume : on ne peut pas faire tourner PG16 sur les fichiers de PG14, et surtout, garder l'ancien volume intact permet de revenir en arrière en une commande si la restauration ou l'application pose problème.

Indisponibilité mesurée : de l'arrêt de PG14 à la fin de la restauration, environ 8,6 s (dont 6,7 s pour initialiser PG16 et 1,2 s de restauration, pour 100 000 commandes). Attention, mon script fait le dump pendant que PG14 accepte encore des écritures : une commande arrivée entre le dump et l'arrêt serait perdue. En vrai, il faut d'abord couper les écritures de l'API, ce qui donne plutôt 10,5 s ici. Le temps de dump et de restauration grandit avec la taille de la base. Pour réduire l'indisponibilité :
- la réplication logique : PG16 est rempli pendant que PG14 tourne, puis on bascule en quelques secondes
- `pg_upgrade --link` (par exemple avec l'image `tianon/postgres-upgrade:14-to-16`, qui contient les deux versions) : il convertit les fichiers sur place avec des liens, sans recopier les données, donc en quelques secondes même pour une grosse base. En contrepartie, une fois PG16 démarré, l'ancien dossier n'est plus utilisable par PG14 : il faut une sauvegarde avant.

## 4. Redis

Testé avec un `kill -9` 2 s après avoir ajouté 2 commandes dans la file :

| configuration | après le crash | perte maximale |
|---|---|---|
| `--save 60 1` | 0 commande | jusqu'à 60 s d'écritures (la dernière photo date de la dernière minute où il y a eu un changement) |
| `--appendonly yes` (fsync chaque seconde) | 2 commandes | environ 1 s |

Dans notre stack, Redis contient le cache des produits, qui se reconstruit tout seul depuis PostgreSQL, et la file `orders:queue`. Une commande perdue de la file reste `pending` en base sans jamais être traitée par le worker. Le cache ne justifie aucune persistance, la file justifie l'AOF : c'est ce qui est configuré au TP04 (`--appendonly yes`). L'autre option serait de reconstruire la file au démarrage du worker à partir des commandes `pending` en base, ce qui demanderait de modifier le code.
