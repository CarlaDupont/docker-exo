# TP09 - CI/CD : de la pull request au déploiement sans interruption

Fait en local, sans compte GitHub, comme le prévoit l'énoncé : le workflow GitHub Actions est écrit, `ci-local.sh` rejoue ses étapes contre le registre du TP03, et `act` exécute le workflow lui-même en conteneur, jusqu'où c'est possible sans GitHub.

- `shop/` : le dépôt demandé (voir `shop/README.md`)
- `lab/` : deux serveurs (préprod et prod, Docker joignable en SSH), le poste qui déploie, et `act`
- `captures/` : les sorties du pipeline local et les mesures d'interruption (copies de terminal)

## 1. Le dépôt

Les commandes du starter pointent vers `jour2-run/.../solution` et `jour1-images/...`, qui n'existent pas dans le support. Le dépôt est assemblé à partir de mes TP : `apps/shopapi` (TP01), `apps/shop-worker` (TP02), la stack du TP04 et `scripts/release-gate.sh` (TP03). Je n'ai pas repris le `.env` du TP01 (le faux secret AWS de l'exercice), `dump-prod-2024.sql`, ni le `pip.conf` du worker.

Le dépôt n'est pas initialisé avec git à l'intérieur de `docker-exo` : un dépôt imbriqué ne serait pas poussé avec `docker-exo`, seulement référencé. Pour les tests, j'en ai fait une copie git hors de `docker-exo`. Les tags `sha-<sha>` des captures viennent de ses commits.

Changements par rapport aux TP précédents :
- Images de base mises à jour. Le scan trivy, qui bloque le pipeline, trouvait 21 failles HIGH ou CRITICAL corrigées dans l'image de l'API (musl, zlib...) et 54 dans celle du worker (openssl, gnupg...), puisque les images de base dataient d'octobre 2024. Je suis passé à `node:22.23.4-alpine3.24` et `alpine:3.24.3` (Node 20 n'est plus maintenu depuis avril 2026), et à `python:3.12.16-slim-trixie`. Résultat : 0 faille pour les deux.
- Sous Node 22, `node --test test/` ne marche plus : un dossier n'est plus accepté en argument (`Cannot find module '/app/test'`). Le script de test devient `node --test test/*.test.js`.
- Chemins de build vers `apps/`. Une seule variable `VERSION` pour l'API et le worker, puisqu'ils sont construits depuis le même commit.
- API : `stop_grace_period: 15s` ; Traefik : middleware `retry` et `dialTimeout` d'1 s (voir étape 4).

## 2. Le pipeline (`shop/.github/workflows/ci.yml`)

| événement | jobs |
|---|---|
| pull request | `lint` (hadolint, `docker compose config`), `build` : étape `test` des Dockerfiles, puis build amd64 + arm64 sans push |
| push sur `main` | + push `sha-<sha>` sur GHCR, scan trivy bloquant (amd64 et arm64), signature cosign keyless, `deploy-preprod` (vérification des signatures, rolling update, smoke test) |
| tag `v*` | `promote` : vérifie la signature de l'image de `main`, puis pose `x.y.z` et `x.y` dessus ; `deploy-prod` dans l'environnement `production` (approbation manuelle), vérification des signatures, rolling update, smoke test |

Points imposés : `docker/metadata-action` (tags et labels OCI, `latest=false` comme le veut la politique du TP03), cache `type=gha` par application, `linux/amd64,linux/arm64`, matrice api / worker, `pip.conf` en secret de build (`secret-files`), `provenance: mode=max` et `sbom: true`.

Choix :
- Sur un tag, je ne reconstruis pas l'image. Un nouveau build donnerait un autre digest, et repousserait un autre contenu sous `sha-<sha>`, que la politique du TP03 veut immuable. `promote` pose les tags semver sur l'image déjà scannée et signée (`docker buildx imagetools create`). La signature porte sur le digest, elle reste donc valable. Si le commit tagué n'est pas passé par `main`, l'image n'existe pas ou n'est pas signée, et la prod n'est pas déployée.
- Le scan a lieu après le push : une image vulnérable peut donc être dans le registre, mais elle n'est pas signée, et les jobs de déploiement refusent toute image sans signature de ce workflow sur `main` (`--certificate-identity .../ci.yml@refs/heads/main`).
- Une version `x.y.z` déjà publiée ne peut plus être déplacée sur un autre digest : la promotion est refusée, et il faut publier une nouvelle version (`x.y`, elle, peut bouger, comme le prévoit le TP03). J'ai ajouté ce contrôle après un essai où un `1.0.0` avait déjà été posé sur un autre commit.
- L'export du cache est en `ignore-error=true` : un service de cache indisponible ne doit pas faire échouer un build correct.
- Les actions sont épinglées par SHA de commit (un tag d'action peut être déplacé, comme lors de l'attaque sur `tj-actions` en 2025), avec la version en commentaire. J'ai vérifié que ces SHA sont bien des commits, et pas des objets tag.
- Sur GitHub, les jobs de déploiement tourneraient sur le runner lui-même (aucun serveur joignable). Le vrai déploiement distant est celui du labo, par `ci-local.sh`.

### En local : `ci-local.sh`

`shop/ci-local.sh pr | main | tag vX.Y.Z` rejoue les mêmes étapes, dans le même ordre, avec trois différences :

| GitHub | en local |
|---|---|
| GHCR | registre du TP03 (`registry.local:5000`, sa CA, compte `ci` pour pousser, `dev` pour tirer) |
| signature keyless (jeton OIDC de GitHub) | signature avec la clé cosign du TP03 (`--tlog-upload=false` : registre privé) |
| environnement `production` avec relecteur obligatoire | confirmation au clavier : il faut taper `oui` |

Les déploiements se font depuis le poste du labo, par contexte Docker (SSH) : préprod pour `main`, prod pour un tag.

| exécution | résultat | capture |
|---|---|---|
| `./ci-local.sh pr` | OK en 1 147 s au premier lancement (build arm64 émulé), 40 s ensuite avec le cache | `ci-local-pr.txt` |
| `./ci-local.sh main` | OK en 141 s : push, 0 CVE sur amd64 et arm64, signature, vérification, rolling update en préprod (51 s), smoke test | `ci-local-main.txt` |
| `echo oui \| ./ci-local.sh tag v1.1.0` | OK en 127 s : signature de l'image de `main` vérifiée, `1.1.0` et `1.1` posés sur le même digest, approbation, signatures vérifiées, déploiement en prod, smoke test | `ci-local-tag.txt` |
| tag sur un commit qui n'est pas passé par `main` | refusé : `signature absente ou invalide` | `ci-local-tag-refus.txt` |
| `tag v1.0.0`, déjà publiée sur un autre digest | refusé : `existe déjà sur un autre digest` | `ci-local-tag-refus.txt` |
| `echo non \| ./ci-local.sh tag v1.2.0` | refusé : `déploiement refusé (réponse : 'non')` | `ci-local-tag-refus.txt` |

Comme sur GitHub, où `promote` passe avant l'attente d'approbation, une version refusée en prod est quand même publiée dans le registre (`1.2.0` ci-dessus). Elle est signée et peut être déployée plus tard.

Pièges rencontrés en écrivant le script :
- Les outils lancés en conteneur avec `docker run -i` lisaient l'entrée standard : le `oui` de l'approbation était consommé par cosign avant le `read`, et la réponse était vide. Mon premier test du refus (`non`) passait donc pour une mauvaise raison. Les outils sont maintenant lancés sans `-i`.
- Sous Git Bash, un chemin `/c/...` donné à `docker.exe` devient `C:\c\...` : le premier `main` a échoué au déploiement (`CreateFile C:\c\Users\...`). Les chemins passés à Docker sont convertis au format Windows.
- Le builder actif était celui du TP02 (en conteneur), qui ne connaît pas la CA du registre. Le script utilise celui du moteur Docker.

### Le workflow avec act

`act` 0.2.92, téléchargé et vérifié avec sa somme de contrôle dans une image (`lab/act`), exécute le vrai `ci.yml` pour l'événement `pull_request` : `docker compose -f lab/compose.yml --profile act run --rm -v <dépôt>:/repo act pull_request -e event.json -P ubuntu-24.04=catthehacker/ubuntu:act-24.04`. Résultat (`act-pr.txt`) :
- job `lint` : il passe entièrement (hadolint, `docker compose config`).
- jobs `build` (api et worker) : ils passent le checkout, QEMU, buildx, le secret `pip.conf` et l'étape `test` des Dockerfiles. Ils s'arrêtent ensuite sur `docker/metadata-action` avec `Bad credentials` : cette action lit les informations du dépôt (description, licence, URL) par l'API GitHub pour les labels OCI. Le dépôt local n'a pas de dépôt GitHub derrière et act n'a pas de vrai jeton, donc cette étape ne peut réussir que sur GitHub.

Le build multi-arch, le push, le scan, la signature et les déploiements sont donc prouvés par `ci-local.sh`, pas par act. Les jobs `main` et `tag` ne peuvent de toute façon pas tourner dans act : ils ont besoin de GHCR, du jeton OIDC de GitHub pour le keyless, et des environnements.

### Autres vérifications
- `actionlint` 1.7.9 (avec shellcheck sur les blocs `run`) : 0 erreur. hadolint : 0 erreur sur les deux Dockerfiles. shellcheck : 0 avertissement sur `ci-local.sh` et les scripts de `deploy/`.
- `docker compose config` sans `.env`, ni secrets, ni `pip.conf` (comme sur un runner) : OK. En prod, il faut `REGISTRY` et `VERSION`, d'où les valeurs factices dans le job `lint`.
- Build amd64 + arm64 avec provenance et SBOM : API en 141 s, worker en 953 s, tests passés aussi en arm64. L'arm64 est émulé (QEMU), d'où la lenteur, surtout pour `pip`.
- Promotion avec `docker buildx imagetools create` (celle du workflow), sur un registre jetable : même digest pour `sha-1234567`, `1.0.0` et `1.0`, signature valide sur `1.0.0`, image non signée refusée (`no signatures found`).

## 3. Déploiement distant

Labo (`lab/`, préparé par `lab/setup.sh`) : les « serveurs » `preprod` (port 8090) et `prod` (port 8092) sont des Docker dans Docker avec sshd, un utilisateur `deploy` dans le groupe `docker`, une connexion par clé uniquement (mot de passe refusé, root interdit), et `dockerd` limité à sa socket unix. Le « poste qui déploie » (`runner`) n'a que le client Docker, et les contextes `preprod` et `prod`. Rien n'est modifié sur Windows. Les images viennent du registre du TP03 : `registry.local` est déclaré et la CA installée uniquement dans les conteneurs des serveurs.

```bash
docker context create preprod --docker "host=ssh://deploy@preprod"
docker --context preprod version        # serveur : 27.3.1, nom : preprod
```

Prérequis côté serveur : Docker installé, un utilisateur `deploy` dans le groupe `docker` (ce qui revient à être root sur la machine : la clé doit être protégée en conséquence), sa clé publique dans `authorized_keys`, et l'authentification par mot de passe désactivée.

Ce que j'ai trouvé en déployant :
- Les bind mounts sont résolus sur le serveur, au chemin calculé par le client. J'ai lancé la commande de l'énoncé alors que le serveur n'avait que `secrets/`. Docker a créé `db/init.sql` sous forme de dossier vide appartenant à root, et l'initialisation de la base a échoué (`shop-db-1 is unhealthy`). Les fichiers montés (`db/`, `secrets/`) doivent exister sur le serveur, au même chemin que sur le poste qui déploie. Dans le labo, le dépôt est en `/srv/shop` des deux côtés, et `compose*.yml` et `db/` sont copiés avec `rsync` avant le déploiement.
- Compose affiche `secret file shop_db_password does not exist`, parce qu'il vérifie le fichier sur le poste qui déploie. Le fichier est bien sur le serveur et le déploiement fonctionne : l'avertissement est trompeur avec un contexte distant.
- Le `.env` est lu par le client, pas par le serveur : `REGISTRY` et `VERSION` sont des variables du poste qui déploie (ou de la CI).
- `docker --context preprod login` : c'est le serveur qui contacte le registre, mais les identifiants sont enregistrés côté client (`~/.docker/config.json` du runner), et transmis à chaque pull.

Comment les secrets arrivent en prod : `secrets/db_password.txt` est créé une fois sur le serveur par un admin (ou par un outil comme Ansible ou Vault), jamais dans git ni dans la CI. Il est dans un dossier en 700 qui appartient à `deploy`, et le fichier est en 444. Il doit être lisible une fois monté, puisque le worker tourne en uid 10001 : un fichier en 600 ne serait lisible que par un conteneur qui a le même uid que `deploy`. La CI n'a besoin que de la clé SSH de déploiement et des identifiants du registre, dans ses secrets.

## 4. Zéro interruption

Mesures avec `deploy/measure-downtime.sh` (100 req/s sur `/health` à travers Traefik, `--max-time 2` par requête). Je les ai lancées depuis le runner : depuis Windows, curl ne dépassait pas 62 req/s. Le runner tient 91 req/s, avec 0 échec sans déploiement.

| déploiement | requêtes | échecs | fichier |
|---|---|---|---|
| naïf : `up -d --force-recreate api` | 4 000 | 459 (451 × 404, 7 × 502, 1 sans réponse) | `1-naif.txt` |
| `rolling-update.sh`, Traefik sans retry | 9 000 | 6 (4 × 502, 2 sans réponse) | `2-rolling-sans-retry.txt` |
| `rolling-update.sh` + retry et `dialTimeout` | 7 000 | 0 (46 s) | `5-rolling.txt` |
| rollback avec `rolling-update.sh` | 7 000 | 0 (47 s) | `4-rollback.txt` |
| naïf, même avec retry | 4 000 | 466 | `6-naif-avec-retry.txt` |

`rolling-update.sh` : il tire les images, ajoute un réplica avec la nouvelle version (`--scale api=N+1 --no-recreate`), attend qu'il soit `healthy`, laisse 5 s à Traefik, arrête un ancien réplica (`docker stop -t 15`, SIGTERM), puis recommence pour chaque réplica. Le worker est recréé à la fin : les commandes attendent dans la file Redis. Si le nouveau réplica n'est jamais `healthy`, il est supprimé et les anciens continuent de servir.

Le rôle de chaque brique, et ce qui se passe sans elle :

| brique | rôle | sans elle |
|---|---|---|
| `HEALTHCHECK` de l'image / healthcheck sur `/ready` | dit quand le conteneur peut vraiment servir | Docker ne fait pas la différence entre « démarré » et « prêt » : Traefik envoie du trafic trop tôt |
| `start_period` | les échecs pendant le démarrage ne comptent pas | un conteneur lent à démarrer serait déclaré `unhealthy` avant d'avoir pu servir |
| `--wait` / l'attente de `healthy` dans le script | on n'arrête un ancien réplica que quand le nouveau est prêt | c'est le déploiement naïf : les deux réplicas sont remplacés en même temps, 459 échecs |
| SIGTERM géré par l'API (`server.close`) | l'API finit les requêtes en cours avant de s'arrêter | coupure en pleine requête (502) |
| `stop_grace_period` / `stop -t 15` | temps laissé après SIGTERM avant SIGKILL | le défaut de Docker est 10 s, une requête longue serait tuée |
| réplicas ≥ 2 | il reste toujours quelqu'un pour servir | avec un seul réplica, rien ne sert pendant la bascule (sauf à en démarrer un deuxième avant) |
| proxy qui ne route que vers les conteneurs `healthy` | le nouveau réplica ne reçoit du trafic qu'une fois prêt | c'est Traefik qui renvoie les 404 du naïf quand aucun réplica n'est prêt |
| `retry` + `dialTimeout` sur Traefik | Traefik met jusqu'à 2 s à prendre en compte un conteneur arrêté : pendant ce temps, la requête est rejouée sur un autre réplica | les 6 échecs de la deuxième mesure : 502 quand l'API a déjà fermé son port, et attente sans fin vers l'adresse d'un conteneur supprimé (30 s de délai de connexion par défaut) |

Piège rencontré : ajouter les labels du `retry` pendant un rolling update a provoqué 1 921 échecs, soit 19 s d'interruption (`3-rolling-changement-de-labels.txt`). Tant que d'anciens et de nouveaux réplicas coexistent, Traefik voit deux définitions différentes du même routeur (`Router defined multiple times with different configurations`) et le supprime. Une modification de la configuration de routage dans les labels ne peut pas passer par un rolling update. Il faut la faire hors trafic, ou la sortir des labels (fichier de configuration de Traefik).

## 5. Rollback

`VERSION=sha-e15f541 ./deploy/rolling-update.sh` : 47 s, 0 échec, et l'API répond de nouveau `sha-e15f541` (`GET /` affiche la version). C'est le même script que pour un déploiement, rien de spécial.

Ce qui le rend possible :
- des tags immuables (`sha-<sha>`, versions) : l'ancienne version désigne toujours exactement le même contenu ;
- les images gardées dans le registre et sur le serveur : pas besoin de reconstruire, et le pull est immédiat si l'image est encore en cache ;
- une base compatible avec les deux versions : le rollback ne touche que les conteneurs, pas les données.

Une migration de schéma non rétro-compatible (colonne supprimée ou renommée) casse ce dernier point : l'ancienne version ne fonctionne plus avec la nouvelle base, et pendant le rolling update, les deux versions tournent en même temps. Il faut découper la migration en étapes compatibles (« expand / contract ») : ajouter la nouvelle colonne, déployer un code qui écrit dans les deux, migrer les données, déployer un code qui ne lit que la nouvelle, et ne supprimer l'ancienne colonne qu'une ou deux versions plus tard. Sinon, le retour arrière demande de restaurer la base (TP05), avec perte des écritures faites depuis.

## Captures (`captures/`, copies de terminal)

- pipeline vert : `ci-local-pr.txt`, `ci-local-main.txt`, `ci-local-tag.txt` ; le workflow dans act, jusqu'à `metadata-action` : `act-pr.txt`
- signature vérifiée : étapes « vérification des signatures » de `ci-local-main.txt` et `ci-local-tag.txt` ; refus : `ci-local-tag-refus.txt`
- mesure naïf / rolling : `1-naif.txt`, `2-rolling-sans-retry.txt`, `3-rolling-changement-de-labels.txt`, `5-rolling.txt`, `6-naif-avec-retry.txt`
- rollback : `4-rollback.txt`
