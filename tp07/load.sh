#!/usr/bin/env bash
# Charge l'API à travers Traefik : 80 % de GET /products, 20 % de POST /orders
# (une commande sur 10 avec quantity=150, que le worker rejette).
# usage : ./load.sh [nombre de requêtes] [requêtes en parallèle]
set -uo pipefail

N=${1:-1000}
PARALLEL=${2:-20}
API=${API_URL:-http://api.localhost}

req() {
  if [ $(( $1 % 5 )) -eq 0 ]; then
    q=2; [ $(( $1 % 50 )) -eq 0 ] && q=150
    curl -s -o /dev/null -w '%{http_code}\n' -m 10 -X POST -H 'Content-Type: application/json' \
      -d "{\"productId\": $(( $1 % 3 + 1 )), \"quantity\": $q}" "$API/orders"
  else
    curl -s -o /dev/null -w '%{http_code}\n' -m 10 "$API/products"
  fi
}
export -f req
export API

start=$(date +%s)
# code 000 = pas de réponse (connexion refusée ou timeout)
seq 1 "$N" | xargs -P "$PARALLEL" -I{} bash -c 'req {}' | sort | uniq -c | awk '{print "HTTP " $2 " : " $1}'
echo "$N requêtes en $(( $(date +%s) - start )) s"
