# syntax=docker/dockerfile:1.10

FROM python:3.12.7-slim-bookworm AS base
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /app

# dépendances de prod dans un venv
FROM base AS builder
ARG TARGETARCH
RUN python -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH
COPY requirements.txt .
# le pip.conf (avec les identifiants du registre) n'existe que pendant ce RUN
# le cache pip est dans un cache mount, il n'arrive pas dans l'image
# hadolint ignore=DL3042
RUN --mount=type=secret,id=pipconf,target=/etc/pip.conf \
    --mount=type=cache,target=/root/.cache/pip,id=pip-${TARGETARCH} \
    pip install -r requirements.txt

# outils de test + lint + tests
FROM builder AS test
ARG TARGETARCH
COPY requirements-dev.txt .
# hadolint ignore=DL3042
RUN --mount=type=secret,id=pipconf,target=/etc/pip.conf \
    --mount=type=cache,target=/root/.cache/pip,id=pip-${TARGETARCH} \
    pip install -r requirements-dev.txt
COPY worker ./worker
COPY tests ./tests
RUN ruff check worker tests && python -m pytest -q tests

FROM base AS runtime
ARG VERSION=0.0.0
ARG GIT_SHA=unknown
LABEL org.opencontainers.image.title="shop-worker" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.source="https://github.com/CarlaDupont/docker-exo" \
      org.opencontainers.image.vendor="Shop SAS"
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin worker
COPY --from=builder /opt/venv /opt/venv
# copié depuis l'étape test : pas d'image finale si les tests échouent
COPY --from=test /app/worker ./worker
ENV PATH=/opt/venv/bin:$PATH
USER worker
EXPOSE 9100
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:9100/metrics', timeout=2)"]
CMD ["python", "-m", "worker.main"]
