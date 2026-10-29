#!/usr/bin/env bash
# Sauvegarde PostgreSQL de la stack : dump logique (pg_dump -Fc) et/ou copie brute du volume.
# usage : ./backup.sh [logique|brute|tout]        (défaut : tout)
# variables : PROJECT (shop), DB_NAME (shop), DB_USER (shop), KEEP (7)
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"

MODE=${1:-tout}
PROJECT=${PROJECT:-shop}
DB_NAME=${DB_NAME:-shop}
DB_USER=${DB_USER:-shop}
KEEP=${KEEP:-7}
VOLUME=${PROJECT}_pgdata
mkdir -p backups
HOSTDIR=$(cd backups && (pwd -W 2>/dev/null || pwd))
DATE=$(date +%Y%m%d-%H%M%S)

DB=$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=db")
[ -n "$DB" ] || { echo "base du projet $PROJECT introuvable (stack arrêtée ?)"; exit 1; }

wait_db() {
  for _ in $(seq 1 30); do
    docker exec "$DB" pg_isready -U "$DB_USER" -d "$DB_NAME" -q && return 0
    sleep 1
  done
  echo "la base ne redémarre pas"; exit 1
}

if [ "$MODE" = logique ] || [ "$MODE" = tout ]; then
  f=backups/$DB_NAME-$DATE.dump
  docker exec "$DB" pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc > "$f"
  # on vérifie que le fichier est lisible par pg_restore
  docker exec -i "$DB" pg_restore --list < "$f" > /dev/null
  echo "dump logique : $f ($(du -h "$f" | cut -f1))"
fi

if [ "$MODE" = brute ] || [ "$MODE" = tout ]; then
  # copie des fichiers du volume : la base doit être arrêtée, sinon la copie peut être incohérente
  f=$VOLUME-$DATE.tar.gz
  docker stop "$DB" > /dev/null
  trap 'docker start "$DB" > /dev/null' EXIT
  docker run --rm -v "$VOLUME:/data:ro" -v "$HOSTDIR:/backup" alpine:3.20.3 tar czf "/backup/$f" -C /data .
  docker start "$DB" > /dev/null
  trap - EXIT
  wait_db
  echo "copie brute : backups/$f ($(du -h "backups/$f" | cut -f1))"
fi

# rétention : les KEEP plus récents de chaque type
ls -1t backups/*.dump 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do rm -f -- "$old"; done
ls -1t backups/*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do rm -f -- "$old"; done
