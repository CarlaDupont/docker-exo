#!/usr/bin/env bash
# release-gate.sh IMAGE [--push REGISTRY_IMAGE]
# Refuse une image qui ne respecte pas la politique Shop SAS.
# Si tout passe et que --push est donné : push, signature cosign et attestation SBOM.
#
# Variables (pour le push) :
#   COSIGN_KEY       clé privée cosign (défaut : cosign.key)
#   COSIGN_PASSWORD  mot de passe de la clé (défaut : vide)
#   REGISTRY_CA      CA du registre (défaut : registry/certs/ca.crt)
#   REGISTRY_AUTH    dossier contenant le config.json docker du compte ci (défaut : client)
#   TOOLS_NETWORK    réseau docker pour joindre le registre depuis les outils en conteneur (défaut : regnet)
#
# Les outils (trivy, syft, cosign, crane, jq) sont utilisés s'ils sont installés, sinon lancés en conteneur.
set -uo pipefail
export MSYS_NO_PATHCONV=1

IMAGE="${1:?usage: release-gate.sh IMAGE [--push REGISTRY_IMAGE]}"
TARGET=""
[ "${2:-}" = "--push" ] && TARGET="${3:?--push demande une référence de destination}"

COSIGN_KEY=${COSIGN_KEY:-cosign.key}
REGISTRY_CA=${REGISTRY_CA:-registry/certs/ca.crt}
REGISTRY_AUTH=${REGISTRY_AUTH:-client}
TOOLS_NETWORK=${TOOLS_NETWORK:-regnet}
export COSIGN_PASSWORD=${COSIGN_PASSWORD:-}

HOSTPWD=$(pwd -W 2>/dev/null || pwd)
WORK=$(mktemp -d ./.gate.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# outil local ou conteneur
run_tool() {
  local bin=$1 image=$2; shift 2
  # type -P : seulement les vrais exécutables (command -v trouverait la fonction elle-même)
  if type -P "$bin" >/dev/null; then
    case $bin in
      # seuls crane et cosign parlent au registre : CA interne et compte ci
      crane|cosign) SSL_CERT_FILE="$REGISTRY_CA" DOCKER_CONFIG="$REGISTRY_AUTH" command "$bin" "$@" ;;
      *)            command "$bin" "$@" ;;
    esac
    return
  fi
  # en conteneur, le dossier courant est monté sur /work : les chemins relatifs restent valables
  local reg=()
  case $bin in
    crane|cosign) reg=(-v "$HOSTPWD/$REGISTRY_CA:/ca.crt:ro" -e SSL_CERT_FILE=/ca.crt
                       -v "$HOSTPWD/$REGISTRY_AUTH:/cfg:ro" -e DOCKER_CONFIG=/cfg) ;;
  esac
  docker run --rm -i --network "$TOOLS_NETWORK" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v trivy-cache:/root/.cache/trivy \
    -v "$HOSTPWD:/work" -w /work \
    "${reg[@]}" -e COSIGN_PASSWORD "$image" "$@"
}
jq()     { run_tool jq     ghcr.io/jqlang/jq:1.7.1 "$@"; }
trivy()  { run_tool trivy  aquasec/trivy:0.57.1 "$@"; }
syft()   { run_tool syft   anchore/syft:v1.16.0 "$@"; }
cosign() { run_tool cosign ghcr.io/sigstore/cosign/cosign:v2.4.1 "$@"; }
crane()  { run_tool crane  gcr.io/go-containerregistry/crane:v0.21.4 "$@"; }

FAILS=0
ok()   { echo "  OK    $*"; }
fail() { echo "  REFUS $*"; FAILS=$((FAILS + 1)); }

echo "== Porte de release : $IMAGE"
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "image introuvable : $IMAGE"; exit 2; }
CONFIG=$(docker image inspect "$IMAGE" --format '{{json .Config}}')

# 1. labels OCI
for l in version revision source; do
  v=$(echo "$CONFIG" | jq -r --arg k "org.opencontainers.image.$l" '.Labels[$k] // empty')
  if [ -n "$v" ]; then ok "label $l = $v"; else fail "label org.opencontainers.image.$l absent"; fi
done

# 2. utilisateur
user=$(echo "$CONFIG" | jq -r '.User // ""')
case "${user%%:*}" in
  ""|root|0) fail "l'image tourne en root (USER='${user}')" ;;
  *)         ok "utilisateur $user" ;;
esac

# 3. healthcheck
hc=$(echo "$CONFIG" | jq -r '.Healthcheck.Test[0] // "NONE"')
if [ "$hc" != "NONE" ]; then ok "HEALTHCHECK défini"; else fail "pas de HEALTHCHECK"; fi

# 4. CVE HIGH/CRITICAL corrigeables
vulns=$(trivy image -q --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed -f json "$IMAGE" \
  | jq '[.Results[]?.Vulnerabilities[]?] | length')
if [ "${vulns:-1}" = 0 ]; then ok "aucune CVE HIGH/CRITICAL corrigeable"
else fail "$vulns CVE HIGH/CRITICAL corrigeable(s) (trivy image --severity HIGH,CRITICAL --ignore-unfixed $IMAGE)"; fi

# 5. secrets : fichiers (trivy) + variables d'environnement de l'image
secrets=$(trivy image -q --scanners secret -f json "$IMAGE" | jq '[.Results[]?.Secrets[]?] | length')
envleak=$(echo "$CONFIG" | jq -r '.Env[]?' \
  | grep -Eic '(PASSWORD|SECRET|TOKEN|API_KEY|ACCESS_KEY)[A-Z_]*=.+|://[^/:@]+:[^/@]+@' || true)
if [ "${secrets:-1}" = 0 ] && [ "$envleak" = 0 ]; then ok "aucun secret détecté"
else fail "secret détecté (fichiers : ${secrets:-?}, variables d'environnement : $envleak)"; fi

if [ "$FAILS" -gt 0 ]; then
  echo "== REFUSÉE : $FAILS contrôle(s) en échec"
  exit 1
fi
echo "== ACCEPTÉE"

[ -z "$TARGET" ] && exit 0

echo "== Publication vers $TARGET"
docker save "$IMAGE" -o "$WORK/image.tar"
crane push "$WORK/image.tar" "$TARGET" >/dev/null 2>&1 || { echo "échec du push"; exit 3; }
DIGEST=$(crane digest "$TARGET")
REF="${TARGET%:*}@$DIGEST"
echo "  poussée : $REF"

syft "$IMAGE" -q -o spdx-json > "$WORK/sbom.json"
echo "  SBOM : $(jq '.packages | length' < "$WORK/sbom.json") paquets"

# --tlog-upload=false : pas de publication dans le journal public Rekor (registre privé)
cosign sign --yes --tlog-upload=false --key "$COSIGN_KEY" "$REF" >/dev/null 2>&1 || { echo "échec de la signature"; exit 4; }
echo "  signée"
cosign attest --yes --tlog-upload=false --key "$COSIGN_KEY" --type spdxjson \
  --predicate "$WORK/sbom.json" "$REF" >/dev/null 2>&1 || { echo "échec de l'attestation"; exit 5; }
echo "  attestation SBOM ajoutée"
echo "== Publiée : $REF"
