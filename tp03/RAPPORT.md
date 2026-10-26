# TP03 - Registre privé et supply chain

## Installation

```bash
cp .env.example .env     # mettre les mots de passe à la place des change-me
./setup.sh
```
`setup.sh` crée la CA et le certificat `registry.local`, les comptes `ci` et `dev`, la clé cosign, puis démarre le registre, le mirror et l'UI (`registry/compose.yml`).

Les images testées viennent du TP01, plus le correctif 1.4.3 :
```bash
cd ../tp01/shopapi
docker build -f Dockerfile.legacy -t shopapi:legacy .
docker build --build-arg APP_VERSION=1.4.2 --build-arg GIT_SHA=$(git rev-parse --short HEAD) -t shopapi:1.4.2 .
cd ../../tp03
docker build --build-arg GIT_SHA=$(git rev-parse --short HEAD) -t shopapi:1.4.3 hotfix
```

Je n'ai modifié ni le fichier hosts, ni les certificats de Windows, ni le `daemon.json` de Docker Desktop. Pour tester comme depuis une vraie machine cliente, le compose a un service `client` (profil `client`, Docker-in-Docker). Il a la CA dans `/etc/docker/certs.d/registry.local:5000/`, résout `registry.local` par le réseau Docker et utilise le mirror. Depuis Windows, je teste avec `curl --resolve registry.local:5000:127.0.0.1 --cacert registry/certs/ca.crt`. Les outils (crane, cosign, trivy, syft) tournent en conteneur.

Ne sont pas versionnés : `.env`, les clés, `htpasswd`, `client/config.json` et `sbom.json`.

## 1. Registre sécurisé

TLS avec une CA interne, auth htpasswd en bcrypt, volume nommé, suppression activée, healthcheck, config dans `config.yml`, UI joxit sur le port 8091 et mirror Docker Hub sur le 5001.

```
curl https://registry.local:5000/v2/                -> 401
curl -u dev:dev-pull-2024 .../v2/_catalog           -> {"repositories":[...]}
curl sans --cacert                                  -> erreur de certificat
docker login registry.local:5000 -u ci              -> Login Succeeded   (depuis le client)
docker push registry.local:5000/shopapi:1.4.2       -> ok
```

Pour le mirror, j'ai fait deux pulls d'`alpine:3.20` : 3,9 s puis 1,7 s. Dans les logs du mirror, chaque blob n'est récupéré sur Docker Hub qu'une seule fois.

**htpasswd suffit-il ?** Non. J'ai testé : le compte `dev` peut pousser, et même supprimer depuis l'UI. htpasswd fait de l'authentification, pas de droits. Harbor, Nexus, Artifactory ou ECR/ACR/GAR apportent les rôles par projet branchés sur l'annuaire, le scan intégré, la réplication, les quotas, l'immutabilité des tags et la rétention.

## 2. API du registre

```bash
curl -u ci:*** https://registry.local:5000/v2/_catalog
curl -u ci:*** https://registry.local:5000/v2/shopapi/tags/list
curl -I -u ci:*** -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json, ..." \
  https://registry.local:5000/v2/shopapi/manifests/1.4.2        # en-tête Docker-Content-Digest
curl -u ci:*** -X DELETE https://registry.local:5000/v2/shopapi/manifests/sha256:...
docker compose exec registry registry garbage-collect --delete-untagged /etc/docker/registry/config.yml
```

Sans le bon `Accept`, le registre renvoie un vieux format de manifeste avec un autre digest.

Quand deux tags pointent sur le même manifeste (`1.4.2` et `stable`), le DELETE par digest supprime les deux. On ne supprime pas un tag, on supprime le manifeste. Le garbage-collect a ensuite libéré 43 Mo.

Piège : après le garbage-collect, mon re-push de `1.4.2` a donné un manifeste introuvable. Le registre garde la liste des blobs en mémoire et croyait encore les avoir. Il faut redémarrer le registre après un GC.

`retention.sh REPO N` garde tous les tags semver et les N autres tags les plus récents (date lue dans la config de l'image). Il ne supprime jamais un digest qui est aussi celui d'un tag gardé. Test avec N=2 : `main-2` et `main-3` sont supprimés, `main-4` et `main-5` gardés. `main-1` est ignoré parce qu'il a le même digest que `1.0.1`.

## 3. Tags

Voir [TAGGING.md](TAGGING.md). Retag sans pull : `crane tag registry.local:5000/shopapi:1.4.2 1.4` (ou `skopeo copy --preserve-digests`). Le digest ne change pas.

## 4. SBOM, scan, signature

- syft : 134 paquets dans le SBOM, dont le binaire node 20.18.0 du TP01
- trivy sur `1.4.2` : 21 CVE HIGH/CRITICAL corrigeables (openssl, musl, zlib d'Alpine 3.20.3), sorties depuis le TP01
- trivy `--scanners secret` sur legacy : il trouve la clé AWS dans `/app/.env`, mais pas le mot de passe de `ENV DATABASE_URL`. La porte de release vérifie donc aussi les variables d'environnement.

```bash
cosign sign --tlog-upload=false --key cosign.key registry.local:5000/shopapi@sha256:1917d5b3...
cosign verify --insecure-ignore-tlog --key cosign.pub registry.local:5000/shopapi:1.4.2   # ok
cosign attest --tlog-upload=false --key cosign.key --type spdxjson --predicate sbom.json registry.local:5000/shopapi@sha256:1917d5b3...
```
J'utilise `--tlog-upload=false` pour ne pas publier la signature dans Rekor, le journal public, puisque c'est une image interne.

Dans le registre, ça crée les tags `sha256-1917d5b3....sig` et `.att` dans le dépôt `shopapi`.

La signature suit le digest, pas le tag. J'ai repoussé une image modifiée sous `1.4.2` : `cosign verify` sur le tag répond `no signatures found`, alors que l'ancien digest est toujours vérifié. C'est une raison de plus pour déployer par digest.

## 5. Porte de release

`./scripts/release-gate.sh IMAGE [--push REGISTRY_IMAGE]` refuse l'image s'il manque un label OCI version, revision ou source, si elle tourne en root, s'il n'y a pas de HEALTHCHECK, s'il y a une CVE HIGH/CRITICAL corrigeable ou si un secret est détecté. Si tout passe, `--push` pousse l'image, puis la signe et attache le SBOM, sur le digest. Les outils installés sont utilisés s'ils sont là (CI), sinon ils tournent en conteneur.

- `shopapi:legacy` est refusée, avec 5 contrôles en échec : labels, root, healthcheck et secrets. Il n'y a « aucune CVE corrigeable », mais seulement parce qu'aucune des 537 CVE HIGH/CRITICAL n'a encore de correctif chez Ubuntu.
- `shopapi:1.4.2` est refusée pour ses 21 CVE. L'énoncé s'attendait à ce qu'elle passe, mais des correctifs sont sortis depuis.
- `shopapi:1.4.3` (1.4.2 + `apk upgrade`, dans `hotfix/`) est acceptée, poussée, signée et attestée. La vraie correction sera de monter la version d'alpine dans le Dockerfile du TP01.
