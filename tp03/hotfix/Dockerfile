# Correctif de sécurité 1.4.3 : shopapi 1.4.2 avec les paquets Alpine à jour (openssl, musl, zlib).
# La vraie correction est de monter la version d'alpine dans le Dockerfile du TP01 au prochain build.
FROM shopapi:1.4.2
USER root
# hadolint ignore=DL3017
RUN apk upgrade --no-cache
USER node
ARG GIT_SHA=unknown
LABEL org.opencontainers.image.version="1.4.3" \
      org.opencontainers.image.revision="${GIT_SHA}"
