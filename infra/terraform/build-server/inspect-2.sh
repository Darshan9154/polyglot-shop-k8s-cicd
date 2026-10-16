#!/bin/bash
# inspect-2.sh - the last details needed before editing dependency files.
set -uo pipefail
R=/opt/polyglot-shop/source/polyglot-shop-k8s-cicd

echo "=== cart explicit jackson block ==="
grep -n -B2 -A4 'jackson-databind' "${R}/src/cart/pom.xml" | head -n 20

echo "=== orders explicit jackson block ==="
grep -n -B2 -A4 'jackson-databind' "${R}/src/orders/pom.xml" | head -n 20

echo "=== checkout files ==="
ls -la "${R}/src/checkout" | head -n 20

echo "=== checkout Dockerfile (any name) ==="
for f in "${R}/src/checkout"/Dockerfile*; do
  [ -f "$f" ] && { echo "--- $f"; cat "$f"; }
done

echo "=== checkout lockfiles ==="
ls -la "${R}/src/checkout"/*.lock "${R}/src/checkout"/yarn.lock "${R}/src/checkout"/package-lock.json 2>/dev/null || echo "(no lockfile at top level)"

echo "=== repo git status ==="
git -C "${R}" status --short | head -n 10
echo "HEAD=$(git -C "${R}" rev-parse --short HEAD)"
