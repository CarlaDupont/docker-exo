#!/usr/bin/env bash
# comptes du registre en bcrypt (cout 10), mots de passe lus dans ../.env
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"
mkdir -p auth ../client
set -a; . ../.env; set +a

docker run --rm httpd:2.4.62-alpine htpasswd -B -C 10 -bn ci "$CI_PASSWORD" | grep . > auth/htpasswd
docker run --rm httpd:2.4.62-alpine htpasswd -B -C 10 -bn dev "$DEV_PASSWORD" | grep . >> auth/htpasswd
cut -d: -f1 auth/htpasswd

# identifiants du compte ci pour les outils (crane, cosign) utilisés par release-gate.sh
printf '{"auths":{"registry.local:5000":{"auth":"%s"}}}\n' "$(printf 'ci:%s' "$CI_PASSWORD" | base64 | tr -d '\n')" > ../client/config.json
echo "client/config.json créé"
