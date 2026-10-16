#!/bin/bash
# compose-up.sh - start the deployment-me stack and report container health.
set -uo pipefail
REPO_DIR='/opt/polyglot-shop/source/polyglot-shop-k8s-cicd'
DEPLOY_DIR="${REPO_DIR}/deployment-me"
cd "${DEPLOY_DIR}" || exit 1

echo "==> build status line"
grep -E 'BUILD_STATUS' /root/resume-build.out || true

echo "==> starting stack at $(date -Is)"
if docker compose up -d --wait --wait-timeout 420; then
  echo "UP_STATUS=success"
else
  echo "UP_STATUS=degraded"
fi

echo "==> containers"
docker compose ps --format 'table {{.Name}}\t{{.Service}}\t{{.State}}\t{{.Status}}'

echo "==> health summary"
docker compose ps --format '{{.Service}}={{.State}}/{{.Health}}'

echo "==> publish ports"
docker compose ps --format '{{.Service}} {{.Publishers}}'
