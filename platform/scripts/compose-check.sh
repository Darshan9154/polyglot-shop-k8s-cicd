#!/bin/bash
# compose-check.sh - validate the deployment-me compose model before building.
# Secrets are deliberately not printed: the .env file is only checked for which
# variable NAMES it defines.
set -uo pipefail
REPO_DIR='/opt/polyglot-shop/source/polyglot-shop-k8s-cicd'
DEPLOY_DIR="${REPO_DIR}/deployment-me"
cd "${DEPLOY_DIR}" || exit 1

echo "==> build contexts"
grep -nE 'context:|image:' docker-compose.yml | sed 's/^[[:space:]]*//'

echo "==> context directories exist?"
for d in ../src/cart ../src/catalog ../src/checkout ../src/orders ../src/ui; do
  if [ -d "${d}" ]; then echo "present: ${d}"; else echo "MISSING: ${d}"; fi
done

echo "==> env variable names defined for compose (values not shown)"
grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' .env 2>/dev/null | tr -d '=' || echo "(no .env entries)"

echo "==> variables referenced by the compose file"
grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*(:-[^}]*)?\}' docker-compose.yml | sort -u || echo "(none)"

echo "==> docker compose config validation"
docker compose config --quiet && echo "COMPOSE_CONFIG=valid" || echo "COMPOSE_CONFIG=invalid"

echo "==> services"
docker compose config --services
