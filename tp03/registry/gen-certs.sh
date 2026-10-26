#!/usr/bin/env bash
# CA interne + certificat serveur pour registry.local
set -euo pipefail
export MSYS_NO_PATHCONV=1
mkdir -p "$(dirname "$0")/certs"
cd "$(dirname "$0")/certs"

if [ ! -f ca.key ]; then
  openssl req -x509 -newkey rsa:4096 -nodes -days 3650 -sha256 \
    -keyout ca.key -out ca.crt -subj "/O=Shop SAS/CN=Shop SAS Internal CA"
fi

openssl req -newkey rsa:2048 -nodes -sha256 \
  -keyout registry.key -out registry.csr -subj "/O=Shop SAS/CN=registry.local"

cat > san.ext <<EXT
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:registry.local,DNS:localhost,IP:127.0.0.1
EXT

openssl x509 -req -in registry.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days 825 -sha256 -extfile san.ext -out registry.crt
rm -f registry.csr san.ext
chmod 644 registry.key
openssl verify -CAfile ca.crt registry.crt
