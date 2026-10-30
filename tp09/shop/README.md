# shop

API (`apps/shopapi`), worker (`apps/shop-worker`), stack Compose et déploiement de *Shop SAS*.

```
apps/            sources et Dockerfiles (TP01, TP02)
compose.yml      stack (TP04) ; compose.prod.yml : images du registre, réplicas, durcissement
db/              init.sql et migrations
deploy/          rolling-update.sh, measure-downtime.sh
scripts/         release-gate.sh (porte de release locale du TP03)
.github/         pipeline GitHub Actions
ci-local.sh      les mêmes étapes, en local, contre le registre du TP03
```

## Lancer la stack

```bash
openssl rand -hex 16 | tr -d '\r\n' > secrets/db_password.txt
cp apps/shop-worker/pip.conf.example apps/shop-worker/pip.conf   # puis l'adapter
docker compose up -d --wait --build
./smoke-test.sh
```

## Pipeline

| événement | étapes |
|---|---|
| pull request | hadolint, `docker compose config`, étape `test` des Dockerfiles, build amd64 + arm64 sans push |
| `main` | + push `sha-<sha>`, scan trivy bloquant, signature cosign, déploiement préprod |
| tag `v*` | tags `x.y.z` et `x.y` posés sur l'image signée de `main` (sans rebuild), approbation, déploiement prod |

Sur GitHub : `.github/workflows/ci.yml` (GHCR, signature keyless, environnement `production` avec relecteur obligatoire).

En local, sans compte GitHub : `ci-local.sh` rejoue les mêmes étapes contre le registre du TP03, et déploie sur les serveurs du labo (`../lab`) :

```bash
../lab/setup.sh                 # une fois : serveurs preprod et prod, contextes Docker
./ci-local.sh pr
./ci-local.sh main              # déploie sha-<commit courant> en préprod
./ci-local.sh tag v1.0.0        # demande une confirmation, puis déploie en prod
```

Variables : `TP03` (dossier du TP03, défaut `../../tp03`), `LAB` (défaut `../lab`), `PLATFORMS` (défaut `linux/amd64,linux/arm64`). Le workflow lui-même s'exécute avec act (voir `../lab`).

## Déploiement sur un serveur

Sur le serveur, préparés une fois par un admin et jamais dans git : `secrets/db_password.txt` (dossier en 700, fichier en 444), et les fichiers montés (`compose*.yml`, `db/`), au même chemin que sur le poste qui déploie.

```bash
docker context create preprod --docker "host=ssh://deploy@preprod"
docker --context preprod login <registre>
DOCKER_CONTEXT=preprod REGISTRY=<registre> VERSION=sha-1a2b3c4 ./deploy/rolling-update.sh
URL=http://preprod ./deploy/measure-downtime.sh 60 100     # pendant un déploiement
```
