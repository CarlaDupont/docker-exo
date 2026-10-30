#!/usr/bin/env bash
# Déploiement sans interruption : les réplicas de l'API sont remplacés un par un.
# usage : REGISTRY=ghcr.io/carladupont VERSION=sha-1a2b3c4 ./deploy/rolling-update.sh
# variables : DOCKER_CONTEXT (hôte cible), STOP_TIMEOUT (15 s), HEALTH_TIMEOUT (90 s), PROXY_DELAY (5 s)
set -euo pipefail
cd "$(dirname "$0")/.."

: "${REGISTRY:?REGISTRY obligatoire}" "${VERSION:?VERSION obligatoire (ex. sha-1a2b3c4)}"
export REGISTRY VERSION
COMPOSE="docker compose -f compose.yml -f compose.prod.yml"
STOP_TIMEOUT=${STOP_TIMEOUT:-15}
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-90}
PROXY_DELAY=${PROXY_DELAY:-5}
start=$(date +%s)

wait_healthy() {
  for _ in $(seq 1 "$HEALTH_TIMEOUT"); do
    case $(docker inspect -f '{{.State.Health.Status}}' "$1") in
      healthy) return 0 ;;
      unhealthy) return 1 ;;
    esac
    sleep 1
  done
  return 1
}

echo "== $VERSION : téléchargement des images"
$COMPOSE pull -q api worker

old=$($COMPOSE ps -q api)
if [ -z "$old" ]; then
  echo "== premier déploiement"
  $COMPOSE up -d --wait
else
  replicas=$(echo "$old" | wc -l)
  # db, redis et proxy ne changent pas : on vérifie seulement qu'ils tournent
  $COMPOSE up -d --wait --no-recreate db redis proxy
  for id in $old; do
    before=$($COMPOSE ps -q api)
    # un réplica de plus, avec la nouvelle image ; les anciens ne sont pas touchés
    $COMPOSE up -d --no-deps --no-recreate --scale "api=$((replicas + 1))" api
    new=$(comm -13 <(echo "$before" | sort) <($COMPOSE ps -q api | sort))
    echo "== nouveau réplica $(docker inspect -f '{{.Name}}' "$new") : attente healthy"
    if ! wait_healthy "$new"; then
      echo "ECHEC : le nouveau réplica n'est pas healthy, on le retire et on garde l'ancienne version"
      docker logs --tail 20 "$new" || true
      docker rm -f "$new" >/dev/null
      exit 1
    fi
    # Traefik ne route que vers les conteneurs healthy ; on lui laisse le temps de le prendre en compte
    sleep "$PROXY_DELAY"
    echo "== arrêt propre de $(docker inspect -f '{{.Name}}' "$id") (SIGTERM, $STOP_TIMEOUT s max)"
    docker stop -t "$STOP_TIMEOUT" "$id" >/dev/null
    docker rm "$id" >/dev/null
  done
  # le worker consomme une file Redis : une courte coupure ne perd rien
  $COMPOSE up -d --no-deps --wait worker
fi

$COMPOSE ps --format 'table {{.Name}}\t{{.Image}}\t{{.Status}}'
echo "== déployé en $(( $(date +%s) - start )) s"
