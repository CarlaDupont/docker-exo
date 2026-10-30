#!/usr/bin/env bash
# Prépare le labo : clé SSH du déploiement, serveurs, fichiers qui n'existent que sur les serveurs,
# contextes Docker et connexion au registre du TP03 sur le poste qui déploie.
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"

mkdir -p ssh
if [ ! -f ssh/id_ed25519 ]; then
  docker run --rm -v "$(pwd -W 2>/dev/null || pwd)/ssh:/k" alpine:3.20.3 sh -c \
    'apk add -q openssh-keygen && ssh-keygen -q -t ed25519 -N "" -C deploy@tp09 -f /k/id_ed25519'
fi
cat > ssh/config <<'EOF'
Host preprod prod
  User deploy
  IdentityFile /root/.ssh/id_ed25519
  StrictHostKeyChecking accept-new
EOF

docker compose up -d --build

for server in preprod prod; do
  # .env et secrets/ : posés sur le serveur par un admin, jamais dans git ni dans la CI
  docker compose exec -T -u deploy "$server" sh -c '
    mkdir -p /srv/shop/secrets
    [ -f /srv/shop/secrets/db_password.txt ] || head -c 16 /dev/urandom | od -An -tx1 | tr -d " \n" > /srv/shop/secrets/db_password.txt
    # dossier fermé ; fichier lisible pour que le worker (uid 10001) puisse le lire une fois monté
    chmod 700 /srv/shop/secrets
    chmod 444 /srv/shop/secrets/db_password.txt'
  docker compose exec -T runner sh -c "docker context inspect $server >/dev/null 2>&1 || docker context create $server --docker host=ssh://deploy@$server >/dev/null"
done

# compte dev du TP03 : lecture seule sur le registre
DEV_PASSWORD=$(grep '^DEV_PASSWORD=' ../../tp03/.env | cut -d= -f2 | tr -d '\r')
echo "$DEV_PASSWORD" | docker compose exec -T runner docker --context preprod login registry.local:5000 -u dev --password-stdin
docker compose exec -T runner docker context ls
