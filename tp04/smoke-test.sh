#!/usr/bin/env bash
# Teste la stack de bout en bout en passant par Traefik.
set -uo pipefail

API=${API_URL:-http://api.localhost}
COMPOSE=${COMPOSE:-docker compose}

ok()   { echo "OK     $*"; }
fail() { echo "ECHEC  $*"; exit 1; }
sql()  { $COMPOSE exec -T db psql -U shop -d shop -tAc "$1"; }

# Traefik met une à deux secondes à prendre en compte un conteneur qui vient de passer healthy
ready=""
for _ in $(seq 1 30); do
  ready=$(curl -fsS "$API/ready" 2>/dev/null) && break
  sleep 1
done
echo "$ready" | grep -q '"status":"ready"' && ok "/ready" || fail "/ready : ${ready:-pas de réponse}"

curl -fsS -o /dev/null "$API/products"
cache=$(curl -fsS -D - -o /dev/null "$API/products" | tr -d '\r' | awk -F': ' 'tolower($1) == "x-cache" {print $2}')
[ "$cache" = HIT ] && ok "/products servi depuis Redis (X-Cache: HIT)" || fail "/products : X-Cache=$cache"

last=$(sql "select coalesce(max(id), 0) from orders")
curl -fsS -X POST -H 'Content-Type: application/json' -d '{"productId":1,"quantity":2}' "$API/orders" >/dev/null \
  && ok "commande créée" || fail "POST /orders"

status=""
for _ in $(seq 1 20); do
  status=$(sql "select status from orders where id > $last order by id desc limit 1")
  [ "$status" = confirmed ] && break
  sleep 1
done
[ "$status" = confirmed ] && ok "commande confirmée par le worker" || fail "statut de la commande : ${status:-introuvable}"
