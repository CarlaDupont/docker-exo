#!/usr/bin/env bash
# Rejoue en local les étapes de .github/workflows/ci.yml, contre le registre du TP03.
#   ./ci-local.sh pr            lint, compose config, tests, build multi-arch sans push
#   ./ci-local.sh main          + push sha-<sha>, scan trivy bloquant, signature cosign, déploiement préprod
#   ./ci-local.sh tag v1.2.3    tags semver sur l'image signée de main, approbation, déploiement prod
# À lancer dans le dépôt git : le tag sha-<sha> vient du commit courant.
#
# Différences avec GitHub : registre du TP03 au lieu de GHCR, signature avec la clé cosign du TP03
# (le keyless demande le jeton OIDC de GitHub), approbation demandée au clavier au lieu de l'environnement.
#
# Variables :
#   TP03       dossier du TP03 : CA du registre, compte ci, clé cosign (défaut ../../tp03)
#   LAB        dossier du labo : serveurs preprod et prod, poste qui déploie (défaut ../lab)
#   PLATFORMS  plateformes construites (défaut linux/amd64,linux/arm64)
#   BUILDER    builder buildx (défaut : celui du moteur, qui fait confiance au registre)
set -eEuo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"

MODE=${1:?usage : ./ci-local.sh pr | main | tag vX.Y.Z}
TP03=$(cd "${TP03:-../../tp03}" && (pwd -W 2>/dev/null || pwd))
LAB=$(cd "${LAB:-../lab}" && (pwd -W 2>/dev/null || pwd))
PLATFORMS=${PLATFORMS:-linux/amd64,linux/arm64}
BUILDER=${BUILDER:-$(docker context show)}
# fichiers de travail ; sous Git Bash, docker.exe a besoin de chemins Windows
WORK=$(mktemp -d)
WORK_W=$(cygpath -m "$WORK" 2>/dev/null || echo "$WORK")
trap 'rm -rf "$WORK"' EXIT
PUSH_REGISTRY=localhost:5000   # le registre vu depuis le poste
REGISTRY=registry.local:5000   # le même, vu depuis les outils et les serveurs (nom du certificat)
SHA=$(git rev-parse --short=7 HEAD)
GIT_SHA=$(git rev-parse HEAD)
export COSIGN_PASSWORD=${COSIGN_PASSWORD:-}

current=""
step() { current=$*; echo; echo "=== $* ($(date +%T))"; }
trap 'echo; echo "PIPELINE EN ÉCHEC : $current"' ERR

# outils en conteneur sur le réseau du registre, avec sa CA et le compte ci du TP03
tool() {
  local image=$1; shift
  # pas de -i : un conteneur lancé avec -i consommerait l'entrée standard (la réponse à l'approbation)
  docker run --rm --network regnet \
    -v "$TP03/registry/certs/ca.crt:/ca.crt:ro" -e SSL_CERT_FILE=/ca.crt \
    -v "$TP03/client:/cfg:ro" -e DOCKER_CONFIG=/cfg \
    -v "$TP03/cosign.key:/cosign.key:ro" -v "$TP03/cosign.pub:/cosign.pub:ro" -e COSIGN_PASSWORD \
    -v trivy-cache:/root/.cache/trivy \
    "$image" "$@"
}
trivy()  { tool aquasec/trivy:0.57.1 "$@"; }
cosign() { tool ghcr.io/sigstore/cosign/cosign:v2.4.1 "$@"; }
crane()  { tool gcr.io/go-containerregistry/crane:v0.21.4 "$@"; }

verify() {
  for img in shop-api shop-worker; do
    cosign verify --key /cosign.pub --insecure-ignore-tlog=true "$REGISTRY/$img:$1" > /dev/null 2>&1 \
      || { echo "signature absente ou invalide : $REGISTRY/$img:$1"; return 1; }
    echo "signature OK : $REGISTRY/$img:$1"
  done
}

# déploiement depuis le poste du labo, par contexte Docker (SSH)
deploy() {
  local env=$1 version=$2
  docker compose -f "$LAB/compose.yml" exec -T \
    -e DOCKER_CONTEXT="$env" -e REGISTRY="$REGISTRY" -e VERSION="$version" runner bash -c "
      set -eo pipefail
      # fichiers montés par la stack : ils doivent exister sur le serveur, au même chemin
      rsync -rt --chmod=D755,F644 compose.yml compose.prod.yml db $env:/srv/shop/
      ./deploy/rolling-update.sh 2>&1 | grep -E '^==|ECHEC'
      API_URL=http://$env HOST_HEADER=api.localhost \
        COMPOSE='docker compose -f compose.yml -f compose.prod.yml' ./smoke-test.sh"
}

lint() {
  step "lint : hadolint"
  for f in apps/shopapi/Dockerfile apps/shop-worker/Dockerfile; do
    docker run --rm -i hadolint/hadolint:v2.12.0 hadolint - < "$f"
    echo "$f : OK"
  done
  step "lint : docker compose config"
  docker compose config -q
  REGISTRY=ghcr.io/exemple VERSION=sha-0000000 docker compose -f compose.yml -f compose.prod.yml config -q
  echo "compose.yml et compose.prod.yml : OK"
}

# build silencieux, journal complet affiché seulement en cas d'échec
quiet() {
  "$@" > "$WORK/log" 2>&1 || { tail -25 "$WORK/log"; return 1; }
  echo OK
}

build() {
  local push=$1
  # pip.conf du worker : secret de build (index privé s'il existe, sinon l'index public)
  if [ -f apps/shop-worker/pip.conf ]; then cp apps/shop-worker/pip.conf "$WORK/pip.conf"
  else printf '[global]\nindex-url = https://pypi.org/simple\n' > "$WORK/pip.conf"; fi

  for app in api worker; do
    case $app in
      api)    image=shop-api;    context=apps/shopapi ;;
      worker) image=shop-worker; context=apps/shop-worker ;;
    esac
    step "$app : étape test du Dockerfile"
    quiet docker buildx build --builder "$BUILDER" --target test --secret "id=pipconf,src=$WORK_W/pip.conf" "$context"

    step "$app : build $PLATFORMS$([ "$push" = 1 ] && echo " et push $PUSH_REGISTRY/$image:sha-$SHA")"
    out=()
    [ "$push" = 1 ] && out=(--push -t "$PUSH_REGISTRY/$image:sha-$SHA" --metadata-file "$WORK_W/$app.json")
    quiet docker buildx build --builder "$BUILDER" --platform "$PLATFORMS" \
      --provenance mode=max --sbom true \
      --build-arg APP_VERSION="sha-$SHA" --build-arg VERSION="sha-$SHA" --build-arg GIT_SHA="$GIT_SHA" \
      --label org.opencontainers.image.created="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --secret "id=pipconf,src=$WORK_W/pip.conf" "${out[@]}" "$context"
    [ "$push" = 1 ] || continue

    digest=$(grep -o '"containerimage.digest": *"sha256:[0-9a-f]*"' "$WORK/$app.json" | grep -o 'sha256:[0-9a-f]*')
    ref="$REGISTRY/$image@$digest"
    echo "poussée : $ref"

    # l'image est dans le registre mais pas signée : le déploiement la refusera si le scan échoue
    step "$app : scan trivy (bloquant)"
    for p in ${PLATFORMS//,/ }; do
      trivy image -q --platform "$p" --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 "$ref" > "$WORK/trivy.txt" \
        || { cat "$WORK/trivy.txt"; return 1; }
      echo "$p : aucune CVE HIGH/CRITICAL corrigeable"
    done

    step "$app : signature cosign"
    cosign sign --yes --tlog-upload=false --key /cosign.key "$ref" > /dev/null 2>&1
    echo "signée : $ref"
  done
}

start=$(date +%s)
case $MODE in
  pr)
    lint
    build 0
    ;;
  main)
    lint
    build 1
    step "préprod : vérification des signatures"
    verify "sha-$SHA"
    step "préprod : déploiement sha-$SHA"
    deploy preprod "sha-$SHA"
    ;;
  tag)
    TAG=${2:?usage : ./ci-local.sh tag vX.Y.Z}
    [[ $TAG =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || { echo "tag invalide : $TAG (attendu vX.Y.Z)"; exit 1; }
    VERSION=${TAG#v}
    MINOR="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    lint
    # le commit tagué doit avoir été construit, scanné et signé sur main : pas de rebuild
    step "promotion : signature de l'image de main"
    verify "sha-$SHA"
    step "promotion : tags $VERSION et $MINOR sur le même digest"
    for img in shop-api shop-worker; do
      # une version publiée est immuable : on refuse de la déplacer sur un autre digest (x.y peut bouger)
      src=$(crane digest "$REGISTRY/$img:sha-$SHA")
      if cur=$(crane digest "$REGISTRY/$img:$VERSION" 2>/dev/null) && [ "$cur" != "$src" ]; then
        echo "$img:$VERSION existe déjà sur un autre digest ($cur) : publier une nouvelle version"
        exit 1
      fi
      crane tag "$REGISTRY/$img:sha-$SHA" "$VERSION"
      crane tag "$REGISTRY/$img:sha-$SHA" "$MINOR"
      echo "$img : sha-$SHA $(crane digest "$REGISTRY/$img:sha-$SHA") = $VERSION $(crane digest "$REGISTRY/$img:$VERSION")"
    done
    step "prod : approbation manuelle"
    answer=""
    read -r -p "Déployer $VERSION en production ? Tapez oui pour confirmer : " answer || true
    [ "$answer" = oui ] || { echo "déploiement refusé (réponse : '${answer}')"; exit 1; }
    echo "approuvé"
    step "prod : vérification des signatures"
    verify "$VERSION"
    step "prod : déploiement $VERSION"
    deploy prod "$VERSION"
    ;;
  *)
    echo "usage : ./ci-local.sh pr | main | tag vX.Y.Z"; exit 1 ;;
esac
echo
echo "PIPELINE OK ($MODE, sha-$SHA) en $(( $(date +%s) - start )) s"
