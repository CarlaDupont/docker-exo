# Politique de tags Shop SAS

## Tags utilisés

| Tag | Exemple | Quand | Immuable |
|---|---|---|---|
| version complète | `1.4.2` | à chaque release | oui |
| version mineure | `1.4` | déplacé à chaque patch de la 1.4 | non |
| commit | `sha-9c02747` | à chaque build de la CI | oui |
| branche | `main`, `main-<n°build>` | build de branche, pour les environnements de dev | non, nettoyé par `retention.sh` |
| pré-release | `1.5.0-rc.1` | recette | oui |

Règles :
- un tag immuable n'est jamais repoussé avec un autre contenu. Si la release est mauvaise, on publie `1.4.3`, on ne réécrit pas `1.4.2`.
- un tag de version n'est poussé que par la CI (compte `ci`), après la porte de release (`release-gate.sh`) : scan, signature et SBOM.
- `retention.sh` ne supprime jamais un tag semver.

## Pourquoi `latest` est interdit en prod

- `latest` ne veut pas dire « la dernière version » : c'est juste le tag par défaut quand on n'en met pas. Il pointe sur ce qui a été poussé en dernier, y compris une branche de test.
- il change sans prévenir : deux nœuds qui tirent `latest` à une heure d'écart peuvent faire tourner deux versions différentes. C'est l'incident du vendredi soir.
- impossible de savoir quelle version tourne, ni de revenir en arrière proprement.
- avec `latest`, Docker ne retélécharge pas l'image si une version est déjà en cache sur la machine, sauf `pull` explicite.

## Référencer une image par digest

Un tag peut être déplacé, un digest non : il est calculé à partir du contenu.

Récupérer le digest :
```bash
crane digest registry.local:5000/shopapi:1.4.2
# ou
curl -sI -u dev:*** --cacert ca.crt \
  -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
  https://registry.local:5000/v2/shopapi/manifests/1.4.2 | grep -i docker-content-digest
```

Dans un `compose.yml` :
```yaml
services:
  api:
    # le tag est là pour la lisibilité, c'est le digest qui est utilisé
    image: registry.local:5000/shopapi:1.4.2@sha256:1917d5b3855f907e644035f79314e3488d393121ae2fe1a439f0f6d4462a9ba6
```

Avec `tag@digest`, Docker ignore le tag et tire exactement le contenu correspondant au digest. Si quelqu'un repousse `1.4.2`, la prod ne bouge pas. La signature cosign porte aussi sur le digest.

Outils comme Renovate ou Dependabot peuvent mettre à jour ces digests automatiquement par pull request.

## Retaguer sans pull

Le retag se fait directement dans le registre, sans télécharger les couches :
```bash
crane tag registry.local:5000/shopapi:1.4.2 1.4
skopeo copy --preserve-digests docker://registry.local:5000/shopapi:1.4.2 docker://registry.local:5000/shopapi:1.4
```
Le digest reste identique (`sha256:1917d5b3…` pour `1.4.2` et `1.4`).

Attention : un `DELETE` par digest supprime tous les tags qui pointent dessus (testé : supprimer `1.4.2` a aussi supprimé `stable`).
