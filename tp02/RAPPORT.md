# TP02 - BuildKit avancé

Livrables : `shop-worker/Dockerfile` et `docker-bake.hcl`. Il y a aussi `Dockerfile.leak` (l'original, pour l'étape 1), `Dockerfile.offline` et `Dockerfile.uv` (bonus), et `buildkitd.toml`, qui autorise le registre local en HTTP.

`pip.conf` n'est pas versionné. Pour le TP il contient seulement :
```
[global]
index-url = https://pypi.org/simple
```

Pour les étapes 4 et 5, j'ai utilisé un registre local en attendant celui du TP03 :
```bash
docker run -d --name registry -p 5000:5000 registry:2.8.3
docker buildx create --name shop --driver docker-container --driver-opt network=host --config buildkitd.toml --use
```

## 1. La fuite

Le build de l'énoncé échoue puisque le registre interne n'existe pas. Pour voir ce que ça donnerait, j'ai remplacé l'URL par `https://svc-ci:Tr3sS3cret@pypi.org/simple` : pypi.org ignore les identifiants et le build va au bout.

On retrouve le mot de passe :
- dans `docker history --no-trunc` : `RUN |1 PIP_INDEX_URL=https://svc-ci:Tr3sS3cret@pypi.org/simple ...`
- dans le `config.json` de l'image, celui qui est poussé au registre (même contenu)
- dans une couche, parce que `COPY . .` embarque `pip.conf.example`
- dans l'attestation de provenance, si on la génère (vu au bonus B2)

## 2. Secret mount

```dockerfile
RUN --mount=type=secret,id=pipconf,target=/etc/pip.conf \
    --mount=type=cache,target=/root/.cache/pip,id=pip-${TARGETARCH} \
    pip install -r requirements.txt
```
```bash
docker build --secret id=pipconf,src=pip.conf -t worker:1.0 .
```

Plus rien dans `docker history`, et `cat /etc/pip.conf` répond `No such file or directory`. J'ai aussi fait un build avec un `pip.conf` contenant le mot de passe, puis cherché `Tr3sS3cret` dans tous les blobs de l'image : 0 occurrence. L'image passe de 1,71 Go à 217 Mo et tourne avec un utilisateur non-root.

Autres solutions : `--mount=type=ssh` pour les dépendances dans un dépôt git privé (avec `--ssh default`), ou `--secret id=TOKEN,env=TOKEN` quand le secret arrive en variable d'environnement, ce qui est le cas courant en CI.

## 3. Cache mount

| Situation | Temps | Téléchargés | Depuis le cache |
|---|---|---|---|
| rebuild sans changement | 3,8 s | - | - |
| `docker builder prune -f` puis ajout de `requests` | 22,9 s | tous | 0 |
| prune des couches seulement, avec cache mount | 22,0 s / 41,9 s | 0 | 16 |
| prune des couches seulement, sans cache mount | 28,5 s / 23,7 s | 16 | 0 |
| `--no-cache` | 21,4 s | 26 | 0 |

Les temps varient beaucoup (après un prune, il faut aussi réextraire l'image de base), donc le nombre de paquets téléchargés est plus parlant.

Le cache de couches évite de rejouer une instruction quand rien n'a changé. Mais dès que `requirements.txt` bouge, tout le `pip install` est refait. Le cache mount, lui, garde le cache de pip entre les builds : l'instruction est rejouée, mais sans retélécharger. Et il ne finit jamais dans l'image.

Deux surprises par rapport à l'énoncé. `docker builder prune -f` vide aussi le cache mount : il faut ajouter `--filter type!=exec.cachemount` pour le garder. Et avec `--no-cache`, le cache mount existait encore mais n'a pas servi, tout a été retéléchargé.

## 4. Multi-architecture

```bash
docker buildx build --platform linux/amd64,linux/arm64 --secret id=pipconf,src=pip.conf \
  -t localhost:5000/shop-worker:1.0 --push .
```

Les deux architectures ensemble avec le push prennent 144 s. Séparément et sans cache : 27 s pour amd64, 160 s pour arm64. Les deux images démarrent (`x86_64` et `aarch64`).

`--push` ou `-o` est obligatoire, parce qu'avec le driver docker-container l'image reste dans le conteneur BuildKit. Et le stockage Docker classique ne peut pas garder plusieurs plateformes sous un même tag. Il faut donc un registre ou une archive OCI.

Le manifest list contient un manifest par plateforme (amd64, arm64) avec son digest, plus un manifest d'attestation pour chacune. Au `pull`, Docker choisit celui de sa plateforme.

`TARGETARCH` est utilisé dans l'id du cache (`id=pip-${TARGETARCH}`), pour que les deux builds n'écrivent pas dans le même cache avec des wheels différentes. On voit bien `pip-amd64` (15 Mo) et `pip-arm64` (13 Mo) dans le builder.

arm64 est 6 fois plus lent parce qu'il est émulé par QEMU sur une machine amd64. La solution est d'ajouter un vrai nœud arm64 au builder (`docker buildx create --append --platform linux/arm64 ssh://...`), ou d'utiliser des runners arm64.

## 5. Cache distant

J'ai vidé complètement le builder, modifié un fichier de test, puis rebuild avec `--cache-from` :
- `mode=min` (53 Mo de cache) : 25 s, tout est rejoué, y compris les dépendances de dev
- `mode=max` (73 Mo) : 15 s, seuls la copie des tests et les tests sont rejoués

`min` n'exporte que les couches de l'image finale. `max` exporte aussi les étapes intermédiaires (builder, test), ce qui sert beaucoup en multi-stage. En CI, on peut utiliser `type=gha` sur GitHub Actions, ou `type=s3` pour des runners sans registre.

## 6. bake

`docker-bake.hcl` contient les variables `VERSION`, `GIT_SHA` et `REGISTRY`, une cible `_common` (plateformes et labels), les cibles `api` (contexte `../tp01/shopapi`) et `worker` avec le cache registre, et `worker-test`, qui s'arrête à l'étape test.

- `docker buildx bake --print` : affiche bien le plan
- `docker buildx bake worker-test` : les tests passent en 3 s
- `docker buildx bake --set "*.platform=linux/amd64" --load` : les deux images en 52 s

Au premier lancement, BuildKit affiche `cache importer: not found`. C'est normal, le cache n'existe pas encore.

## Bonus

**B1** : pip interroge l'index même quand tout est en cache. `Dockerfile.offline` télécharge donc les wheels dans un cache mount (étape `prefetch`, avec réseau), puis installe avec `--network=none` et `--no-index`. Le build complet passe sans réseau. Utile pour les environnements isolés, ou pour être sûr de n'utiliser que des dépendances déjà vérifiées.

**B2** : la provenance contient les build args, l'image de base et l'id du secret (`pipconf`), jamais son contenu. Avec l'ancien Dockerfile, par contre, le mot de passe passé en `ARG` y apparaît en clair. Le SBOM liste 124 paquets, sans pytest ni ruff.

**B3** : avec uv, environ 25 à 35 % plus rapide que pip (21 s contre 28 s à vide, 15 s contre 23 s avec le cache), et une image de 198 Mo. uv ne lit pas `pip.conf`, j'ai donc passé l'URL de l'index en secret (`--secret id=uv_index,env=UV_INDEX_URL`).
