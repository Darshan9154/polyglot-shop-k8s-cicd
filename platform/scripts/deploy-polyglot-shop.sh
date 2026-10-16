#!/bin/bash
# deploy-polyglot-shop.sh - clone the user's repository and run its Compose stack.
# Safe to re-run: the clone is refreshed and the stack is rebuilt in place.
set -uo pipefail
REPO_URL='https://github.com/Darshan9154/polyglot-shop-k8s-cicd.git'
BASE_DIR='/opt/polyglot-shop'
REPO_DIR="${BASE_DIR}/source/polyglot-shop-k8s-cicd"

echo "==> prepare directories"
mkdir -p "${BASE_DIR}/source"

echo "==> clone or refresh"
if [ -d "${REPO_DIR}/.git" ]; then
  git -C "${REPO_DIR}" fetch --depth 1 origin && git -C "${REPO_DIR}" reset --hard FETCH_HEAD
else
  git clone "${REPO_URL}" "${REPO_DIR}"
fi
echo "HEAD=$(git -C "${REPO_DIR}" rev-parse HEAD)"
chown -R ubuntu:ubuntu "${BASE_DIR}"

echo "==> repository top level"
ls -la "${REPO_DIR}"

echo "==> directories named deploy..."
find "${REPO_DIR}" -maxdepth 3 -type d -iname '*deploy*' -not -path '*/.git/*' 2>/dev/null

echo "==> compose files"
find "${REPO_DIR}" -maxdepth 4 -type f \( -iname 'docker-compose*.yml' -o -iname 'docker-compose*.yaml' -o -iname 'compose*.yml' -o -iname 'compose*.yaml' \) -not -path '*/.git/*' 2>/dev/null | sort
