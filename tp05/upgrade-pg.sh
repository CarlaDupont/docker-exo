#!/usr/bin/env bash
# Montée de version PostgreSQL 14 -> 16 de la base legacy (legacy/compose.yml).
# L'ancien volume (PG14) n'est pas modifié : retour arrière possible tant qu'on ne l'a pas supprimé.
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/legacy"

PG14="docker compose -f compose.yml"
PG16="docker compose -f compose.yml -f compose.pg16.yml"
DIR=../backups/upgrade
DATE=$(date +%Y%m%d-%H%M%S)
mkdir -p "$DIR"

if docker volume inspect shopdata_pgdata16 > /dev/null 2>&1; then
  echo "le volume shopdata_pgdata16 existe déjà : montée de version déjà faite ?"
  exit 1
fi

echo "== 1. état avant (PostgreSQL $($PG14 exec -T db psql -U shop -d shop -tAc 'show server_version'))"
$PG14 exec -T db psql -U shop -d shop -tA < ../checksum.sql | tee "$DIR/avant-$DATE.txt"

echo "== 2. sauvegardes"
$PG14 exec -T db pg_dumpall -U shop > "$DIR/dumpall-$DATE.sql"
$PG14 exec -T db pg_dump -U shop -d shop -Fc > "$DIR/shop-$DATE.dump"
ls -lh "$DIR/dumpall-$DATE.sql" "$DIR/shop-$DATE.dump" | awk '{print $5, $9}'

echo "== 3. arrêt de PostgreSQL 14 (volume conservé)"
$PG14 stop db

echo "== 4. PostgreSQL 16 sur un nouveau volume"
$PG16 up -d --wait db

echo "== 5. restauration"
$PG16 exec -T db pg_restore -U shop -d shop --single-transaction < "$DIR/shop-$DATE.dump"

echo "== 6. état après (PostgreSQL $($PG16 exec -T db psql -U shop -d shop -tAc 'show server_version'))"
$PG16 exec -T db psql -U shop -d shop -tA < ../checksum.sql | tee "$DIR/apres-$DATE.txt"

if diff -q "$DIR/avant-$DATE.txt" "$DIR/apres-$DATE.txt" > /dev/null; then
  echo "== VERDICT : OK, données identiques"
else
  echo "== VERDICT : ECHEC, les checksums diffèrent"
  echo "retour arrière : docker compose -f compose.yml up -d   (dans legacy/)"
  exit 1
fi
