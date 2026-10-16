#!/bin/bash
# stop-stack-clean.sh - shut the Compose stack down cleanly before the instance stops.
#
# Why a graceful stop first: the containers include MariaDB, PostgreSQL, Redis and
# DynamoDB Local. An abrupt instance stop can leave a database needing recovery on next
# boot. `docker compose stop` sends SIGTERM and waits, so the volumes stay consistent.
#
# Why NOT `down -v`: that deletes the named volumes, which would discard the catalog's
# 12 seeded products and the other data. Stopping keeps the volumes for tomorrow.
set -uo pipefail
R=/opt/polyglot-shop/source/polyglot-shop-k8s-cicd
cd "${R}/deployment-me" || exit 1

echo "=== state before stop ==="
docker compose ps --format '{{.Service}}={{.State}}/{{.Health}}'

echo "=== graceful stop (volumes preserved) ==="
docker compose stop
echo "STOP_EXIT=$?"

echo "=== containers after stop ==="
docker compose ps --format '{{.Service}}={{.State}}'

echo "=== volumes preserved (data for tomorrow) ==="
docker volume ls --format '{{.Name}}' | grep -i deployment-me || echo "(none)"
