variable "VERSION" {
  default = "dev"
}

variable "GIT_SHA" {
  default = "unknown"
}

# registre pour les tags et le cache (vide = pas de cache distant)
variable "REGISTRY" {
  default = "localhost:5000"
}

group "default" {
  targets = ["api", "worker"]
}

target "_common" {
  platforms = ["linux/amd64", "linux/arm64"]
  labels = {
    "org.opencontainers.image.version"  = VERSION
    "org.opencontainers.image.revision" = GIT_SHA
    "org.opencontainers.image.vendor"   = "Shop SAS"
  }
}

target "api" {
  inherits   = ["_common"]
  context    = "../tp01/shopapi"
  dockerfile = "Dockerfile"
  args = {
    APP_VERSION = VERSION
    GIT_SHA     = GIT_SHA
  }
  tags       = ["${REGISTRY}/shopapi:${VERSION}"]
  cache-from = REGISTRY != "" ? ["type=registry,ref=${REGISTRY}/cache:api"] : []
  cache-to   = REGISTRY != "" ? ["type=registry,ref=${REGISTRY}/cache:api,mode=max"] : []
}

target "worker" {
  inherits   = ["_common"]
  context    = "shop-worker"
  dockerfile = "Dockerfile"
  args = {
    VERSION = VERSION
    GIT_SHA = GIT_SHA
  }
  secret     = ["id=pipconf,src=shop-worker/pip.conf"]
  tags       = ["${REGISTRY}/shop-worker:${VERSION}"]
  cache-from = REGISTRY != "" ? ["type=registry,ref=${REGISTRY}/cache:worker"] : []
  cache-to   = REGISTRY != "" ? ["type=registry,ref=${REGISTRY}/cache:worker,mode=max"] : []
}

# lance seulement l'étape test (lint + pytest), sans produire d'image
target "worker-test" {
  inherits  = ["worker"]
  target    = "test"
  platforms = []
  tags      = []
  cache-to  = []
  output    = ["type=cacheonly"]
}
