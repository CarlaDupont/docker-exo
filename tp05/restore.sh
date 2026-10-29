#!/usr/bin/env bash
# Restaure une sauvegarde faite par backup.sh.
# usage : ./restore.sh backups/shop-AAAAMMJJ-HHMMSS.dump      (dump logique)
#         ./restore.sh backups/shop_pgdata-AAAAMMJJ-HHMMSS.tar.gz   (copie brute du volume)
set -euo pipefail
export MSYS_NO_PATHCONV=1

FILE=${1:?usage : ./restore.sh FICHIER}
[ -f "$FILE" ] || { echo "fichier introuvable : $FILE"; exit 1; }
FILE=$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")
cd "$(dirname "$0")"

PROJECT=${PROJECT:-shop}
DB_NAME=${DB_NAME:-shop}
DB_USER=${DB_USER:-shop}
VOLUME=${PROJECT}_pgdata

DB=$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=db")
[ -n "$DB" ] || { echo "base du projet $PROJECT introuvable (stack arrêtée ?)"; exit 1; }

case $FILE in
  *.dump)
    # --clean --if-exists : remplace les objets existants ; tout ou rien grâce à --single-transaction
    docker exec -i "$DB" pg_restore -U "$DB_USER" -d "$DB_NAME" --clean --if-exists --single-transaction < "$FILE"
    ;;
  *.tar.gz)
    dir=$(cd "$(dirname "$FILE")" && (pwd -W 2>/dev/null || pwd))
    name=$(basename "$FILE")
    docker stop "$DB" > /dev/null
    docker run --rm -v "$VOLUME:/data" -v "$dir:/backup:ro" alpine:3.20.3 \
      sh -c "find /data -mindepth 1 -delete && tar xzf /backup/$name -C /data"
    docker start "$DB" > /dev/null
    for _ in $(seq 1 30); do docker exec "$DB" pg_isready -U "$DB_USER" -q && break; sleep 1; done
    ;;
  *)
    echo "format inconnu : $FILE"; exit 1 ;;
esac

echo "restauré depuis $FILE"
docker exec -i "$DB" psql -U "$DB_USER" -d "$DB_NAME" -tA < checksum.sql
