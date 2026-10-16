#!/bin/bash
# compose-build.sh - build every service image from deployment-me/docker-compose.yml.
set -uo pipefail
REPO_DIR='/opt/polyglot-shop/source/polyglot-shop-k8s-cicd'
DEPLOY_DIR="${REPO_DIR}/deployment-me"
LOG="${DEPLOY_DIR}/compose-build.log"
cd "${DEPLOY_DIR}" || exit 1

echo "==> docker version: $(docker --version)"
echo "==> free memory: $(free -m | awk '/Mem:/{print $7" MiB available"}')"
echo "==> build starting at $(date -Is)"

if docker compose build 2>&1 | tee "${LOG}"; then
  echo "BUILD_STATUS=success"
else
  echo "BUILD_STATUS=failed"
  echo "==> last 40 lines"
  tail -n 40 "${LOG}"
fi

echo "==> images"
docker images --format '{{.Repository}}:{{.Tag}} {{.Size}}' | head -n 20
