#!/usr/bin/env bash
# installation complète : certificats, comptes, clé cosign, démarrage du registre
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  cp .env.example .env
  echo "Fichier .env créé : mettre les mots de passe puis relancer ./setup.sh"
  exit 1
fi
if grep -q change-me .env; then
  echo "Le fichier .env contient encore change-me"
  exit 1
fi

./registry/gen-certs.sh
./registry/gen-htpasswd.sh

HOSTPWD=$(pwd -W 2>/dev/null || pwd)
if [ ! -f cosign.key ]; then
  docker run --rm -v "$HOSTPWD:/work" -w /work -e COSIGN_PASSWORD= \
    ghcr.io/sigstore/cosign/cosign:v2.4.1 generate-key-pair
fi

cd registry
docker compose up -d --wait
docker compose ps
