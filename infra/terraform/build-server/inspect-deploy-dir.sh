#!/bin/bash
# inspect-deploy-dir.sh - show the deployment-me directory and its compose file.
set -uo pipefail
REPO_DIR='/opt/polyglot-shop/source/polyglot-shop-k8s-cicd'
echo "==> deployment-me tree"
find "${REPO_DIR}/deployment-me" -not -path '*/.git/*' | sort
echo "==> docker-compose.yml"
cat "${REPO_DIR}/deployment-me/docker-compose.yml"
echo "==> any env files"
find "${REPO_DIR}/deployment-me" -maxdepth 2 -type f -name '.env*' -exec sh -c 'echo "--- {}"; cat "{}"' \;
