# syntax=docker/dockerfile:1.7

FROM node:20.18.0-alpine3.20 AS base
WORKDIR /app

# dépendances de prod seulement, rejouées uniquement si package*.json change
FROM base AS deps
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --omit=dev --ignore-scripts

# tests et lint avec les dépendances de dev
FROM base AS test
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --ignore-scripts
COPY src ./src
COPY test ./test
RUN npm test && npm run lint

# image finale : alpine + binaire node seul (sans npm ni yarn, inutiles en prod)
FROM alpine:3.20.3 AS runtime
RUN apk add --no-cache libstdc++=13.2.1_git20240309-r1 libgcc=13.2.1_git20240309-r1 \
 && addgroup -g 1000 node \
 && adduser -u 1000 -G node -s /sbin/nologin -D node
COPY --from=base /usr/local/bin/node /usr/local/bin/node
WORKDIR /app

ARG APP_VERSION=0.0.0
ARG GIT_SHA=unknown
ARG SOURCE_URL=https://github.com/CarlaDupont/docker-exo
LABEL org.opencontainers.image.title="shopapi" \
      org.opencontainers.image.description="API catalogue produits" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.vendor="Shop SAS"
ENV NODE_ENV=production \
    APP_VERSION=${APP_VERSION}

COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
# copié depuis l'étape test : l'image finale n'est construite que si les tests passent
COPY --from=test /app/src ./src

USER node
EXPOSE 3000
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:3000/health').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"]
CMD ["node", "src/server.js"]
