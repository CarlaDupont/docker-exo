#!/usr/bin/env bash
# retention.sh REPO N : garde les N tags hors semver les plus récents, supprime les autres.
# Les tags semver (1.2.3, v1.2.3, 1.2.3-rc.1) ne sont jamais supprimés.
#
# Variables :
#   REGISTRY      https://registry.local:5000
#   REG_USER      ci
#   REG_PASSWORD  (obligatoire)
#   CURL_OPTS     options curl en plus, ex. "--cacert registry/certs/ca.crt"
#   DRY_RUN=1     affiche sans supprimer
set -euo pipefail

REPO=${1:?usage: retention.sh REPO N}
KEEP=${2:?usage: retention.sh REPO N}
REGISTRY=${REGISTRY:-https://registry.local:5000}
REG_USER=${REG_USER:-ci}
REG_PASSWORD=${REG_PASSWORD:?REG_PASSWORD manquant}
DRY_RUN=${DRY_RUN:-0}

command -v jq >/dev/null || jq() { docker run --rm -i ghcr.io/jqlang/jq:1.7.1 "$@"; }

ACCEPT='application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'
SEMVER='^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'

api() { curl -fsS ${CURL_OPTS:-} -u "$REG_USER:$REG_PASSWORD" "$@"; }

digest_of() {
  api -I -H "Accept: $ACCEPT" "$REGISTRY/v2/$REPO/manifests/$1" \
    | grep -i '^docker-content-digest:' | tr -d '\r' | cut -d' ' -f2
}

# date de création lue dans la config de l'image (1re plateforme si c'est un index)
created_of() {
  local m cfg
  m=$(api -H "Accept: $ACCEPT" "$REGISTRY/v2/$REPO/manifests/$1")
  if echo "$m" | jq -e '.manifests' >/dev/null 2>&1; then
    local first
    first=$(echo "$m" | jq -r '[.manifests[] | select(.platform.os != "unknown")][0].digest')
    m=$(api -H "Accept: $ACCEPT" "$REGISTRY/v2/$REPO/manifests/$first")
  fi
  cfg=$(echo "$m" | jq -r '.config.digest')
  api "$REGISTRY/v2/$REPO/blobs/$cfg" | jq -r '.created // "1970-01-01T00:00:00Z"'
}

tags=$(api "$REGISTRY/v2/$REPO/tags/list" | jq -r '.tags // [] | .[]')
[ -z "$tags" ] && { echo "aucun tag dans $REPO"; exit 0; }

declare -A DIGEST
keep_tags=()
others=""
for t in $tags; do
  DIGEST[$t]=$(digest_of "$t")
  if [[ $t =~ $SEMVER ]]; then
    keep_tags+=("$t")
  else
    others+="$(created_of "$t") $t"$'\n'
  fi
done

# tri du plus récent au plus ancien
sorted=$(printf '%s' "$others" | sort -r | awk 'NF {print $2}')
recent=$(echo "$sorted" | head -n "$KEEP")
old=$(echo "$sorted" | tail -n +"$((KEEP + 1))")
for t in $recent; do keep_tags+=("$t"); done

echo "gardés : ${keep_tags[*]}"

# un digest gardé ne doit pas être supprimé : DELETE par digest enlèverait tous ses tags
protected=" "
for t in "${keep_tags[@]}"; do protected+="${DIGEST[$t]} "; done

for t in $old; do
  d=${DIGEST[$t]}
  if [[ $protected == *" $d "* ]]; then
    echo "ignoré : $t (même digest qu'un tag gardé)"
  elif [ "$DRY_RUN" = 1 ]; then
    echo "à supprimer : $t ($d)"
  else
    api -X DELETE "$REGISTRY/v2/$REPO/manifests/$d" -o /dev/null
    echo "supprimé : $t ($d)"
    protected+="$d "
  fi
done

echo "Penser au garbage-collect pour libérer l'espace disque :"
echo "  docker compose exec registry registry garbage-collect --delete-untagged /etc/docker/registry/config.yml"
