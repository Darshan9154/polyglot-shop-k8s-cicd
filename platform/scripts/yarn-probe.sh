#!/bin/bash
# yarn-probe.sh - reproduce the checkout install once, read-only, to learn which
# yarn the Docker build really uses and whether --frozen-lockfile is satisfied.
set -uo pipefail
SRC=/opt/polyglot-shop/source/polyglot-shop-k8s-cicd/src/checkout

echo "=== corepack/bin presence in the checkout tree ==="
ls -la "${SRC}/.yarn" 2>/dev/null || echo "(no .yarn dir)"
find "${SRC}" -maxdepth 2 -name '.yarnrc.yml' -o -maxdepth 2 -name 'yarn-*.cjs' 2>/dev/null | head

echo "=== does the repo root provide yarn 4? ==="
ls -la /opt/polyglot-shop/source/polyglot-shop-k8s-cicd/.yarn/releases 2>/dev/null | head

echo "=== reproduce install (read-only mount) ==="
docker run --rm -v "${SRC}":/app:ro -w /app -e COREPACK_ENABLE_DOWNLOAD_PROMPT=0 node:20-alpine \
  sh -c '
    set +e
    echo "yarn: $(yarn --version 2>&1 | head -n 1)"
    echo "--- frozen install attempt ---"
    yarn install --frozen-lockfile --non-interactive 2>&1 | tail -n 12
    echo "FROZEN_EXIT=$?"
  ' 2>&1 | tail -n 25
