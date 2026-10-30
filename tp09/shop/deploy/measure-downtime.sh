#!/usr/bin/env bash
# Envoie des requêtes à rythme constant sur /health, à travers le proxy, et compte les échecs.
# usage : ./deploy/measure-downtime.sh [durée en s] [requêtes/s]      (défaut : 60 s à 100 req/s)
# variables : URL (http://localhost), HOST_HEADER (api.localhost)
set -uo pipefail

DURATION=${1:-60}
RATE=${2:-100}
URL=${URL:-http://localhost}
HOST_HEADER=${HOST_HEADER:-api.localhost}
N=$((DURATION * RATE))

echo "$N requêtes sur $URL/health (Host: $HOST_HEADER) à $RATE req/s"
start=$(date +%s)
# un seul processus curl : --rate espace les requêtes, --max-time vaut pour chacune
curl -s --rate "${RATE}/s" --max-time 2 -H "Host: $HOST_HEADER" \
     -w '\n@@ %{http_code} %{time_total}\n' "$URL/health?n=[1-$N]" 2>/dev/null \
  | awk -v start="$start" '
      /^@@ / {
        total++; code[$2]++
        if ($2 != 200) { ko++; if (!first) first = total; last = total }
        if ($3 > max) max = $3
      }
      END {
        printf "réponses : %d, échecs : %d\n", total, ko
        for (c in code) printf "  HTTP %s : %d\n", (c == "000" ? "000 (pas de réponse)" : c), code[c]
        if (ko) printf "échecs entre la requête %d et la %d\n", first, last
        printf "temps de réponse max : %.3f s\n", max
      }'
echo "durée réelle : $(( $(date +%s) - start )) s"
