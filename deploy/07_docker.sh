#!/usr/bin/env bash
step "STEP 7/8 -- Docker: build + pull + start"

cd "${PROJECT_DIR}"

# ── 1. Build Postfix image (only locally-built image in the stack) ─────────
echo
ok "Building Postfix image (debian:bookworm-slim + postfix + libsasl2-modules)..."
docker build --no-cache -t bitrix_postfix:latest ./confs/postfix/
ok "Image bitrix_postfix:latest built"
docker images bitrix_postfix:latest

# ── 2. Pull all other images from registries ──────────────────────────────
# Images used in docker-compose.yml:
#   quay.io/bitrix24/percona-server:8.0.45-v1-rhel   <- MySQL
#   quay.io/bitrix24/php:8.2.31-fpm-v1-alpine        <- PHP-FPM + cron
#   quay.io/bitrix24/nginx:1.30.2-v1-alpine          <- nginx
#   quay.io/bitrix24/push:3.3-v1-alpine              <- push pub/sub
#   quay.io/bitrix24/ssl:1.2-v1-alpine               <- SSL manager
#   redis:8.2.7-alpine                               <- Redis
#   opensearchproject/opensearch:2.18.0              <- OpenSearch
echo
ok "Pulling images from registries (first run may take 5-15 min)..."
docker compose pull
ok "All images pulled"

# ── 3. Start all 10 containers ────────────────────────────────────────────
echo
ok "Starting Docker stack (10 containers)..."
docker compose up -d

echo
ok "docker compose up -d complete. Container status:"
docker compose ps

echo
ok "Waiting 30s for services to initialize..."
sleep 30