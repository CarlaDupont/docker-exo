# TP01 - Rapport

Dans `shopapi/` : le nouveau `Dockerfile`, `Dockerfile.distroless` (bonus B1), l'ancien `Dockerfile.legacy` gardé pour comparer, le `.dockerignore` et un `package-lock.json` (nécessaire pour `npm ci`, le code n'a pas changé). Le diagnostic est dans [DIAGNOSTIC.md](DIAGNOSTIC.md).

```bash
cd shopapi
docker build --build-arg APP_VERSION=1.4.2 --build-arg GIT_SHA=$(git rev-parse --short HEAD) -t shopapi:1.4.2 .
docker build --target test -t shopapi:test .
```

## Avant / après

| | legacy | 1.4.2 |
|---|---|---|
| Taille | 1,09 Go | 171 Mo (45 Mo compressés) |
| Couches | 9 | 7 |
| Rebuild après un changement de code | 17 s, `npm install` rejoué | 7,6 s, dépendances en cache |
| Utilisateur | root | node (1000) |
| `docker stop` | 10,5 s, tué (137) | 0,5 s, exit 0 |
| hadolint | 6 warnings | rien |

Les secrets, les dépendances de dev, le dump et le `.env` ne sont plus dans l'image. Il y a un HEALTHCHECK et les labels OCI version, revision et source.

Pour la taille : avec `node:20-alpine` complète j'étais à 208 Mo dans `docker image ls` (Docker Desktop additionne la taille compressée et décompressée). L'étape finale part donc d'`alpine:3.20.3` avec seulement le binaire `node` de l'image officielle. Pas de npm ni de yarn en prod, ce qui fait 21 Mo de moins.

## Pourquoi npm install était rejoué

`COPY . /app` était placé avant `npm install`. Le moindre fichier modifié invalide cette couche et tout ce qui suit. Il faut copier d'abord `package.json` et `package-lock.json`, faire `npm ci`, et seulement ensuite copier `src`. Après un commentaire ajouté dans `server.js`, `npm ci` reste maintenant en cache : seuls la copie des sources et les tests (1,2 s) sont rejoués.

## Arrêt en 0,5 s au lieu de 10 s

Avec `CMD npm start`, le PID 1 est `/bin/sh`, qui ne transmet pas SIGTERM à node. Docker attend donc 10 s puis envoie SIGKILL. Avec `CMD ["node", "src/server.js"]`, node est le PID 1 et le gestionnaire SIGTERM déjà présent dans `server.js` ferme proprement le serveur.

## Le Dockerfile

Trois étapes : `deps` (dépendances de prod avec `npm ci --omit=dev`), `test` (toutes les dépendances, `npm test` et `npm run lint`) et `runtime`. L'image finale copie `src` depuis l'étape `test`. Sans ça, BuildKit ne construirait pas l'étape test quand on build l'image finale, et une image pourrait sortir avec des tests cassés.

Le `.dockerignore` est une liste blanche : seuls `package*.json`, `src/` et `test/` partent au build.

```
$ docker run --rm -i hadolint/hadolint:v2.12.0 < Dockerfile
$ echo $?
0
```

## Bonus

**B1, distroless** : `gcr.io/distroless/nodejs20-debian12:nonroot`, 47 Mo compressés, healthy. Il n'y a pas de shell (`docker exec api sh` échoue), donc c'est plus sûr mais plus pénible à déboguer. Sans wget, le healthcheck passe par node et `fetch()`.

**B2, cache mount npm** : 11,5 s et 9,7 s sans le cache, 8,9 s et 9,2 s avec. Peu de gain ici : il y a peu de dépendances et le réseau est rapide.

**B3, reproductible** : sans précaution, deux builds donnent deux digests différents. Avec `SOURCE_DATE_EPOCH` et `rewrite-timestamp=true`, j'obtiens le même digest (`sha256:7eed332a…`). Ce qui casse la reproductibilité, ce sont surtout les dates (config de l'image et fichiers des couches). Viennent ensuite les dépendances non figées, et les images de base référencées par tag plutôt que par digest.
