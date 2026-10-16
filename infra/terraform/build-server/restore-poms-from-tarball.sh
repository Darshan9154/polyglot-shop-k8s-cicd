#!/bin/bash
# restore-poms-from-tarball.sh - restore the three service POMs from the pristine
# archive taken before the migration, then rebuild everything.
#
# Why not git: in this script's context git refuses the repository with "dubious
# ownership" even after a global safe.directory write, so every earlier restore silently
# did nothing. The tarball is independent of git and is the reliable recovery path.
set -uo pipefail
R=/opt/polyglot-shop/source/polyglot-shop-k8s-cicd
TARBALL=/root/cart-before-sb4.tgz

echo "=== tarball contents (poms only) ==="
tar tzf "${TARBALL}" | grep 'pom.xml$'

echo "=== current parent versions (before) ==="
for svc in cart orders ui; do
  echo "  ${svc}: $(sed -n '/<parent>/,/<\/parent>/p' "${R}/src/${svc}/pom.xml" | grep -o '<version>[^<]*' | head -n 1)"
done

echo "=== restore POMs ==="
tar xzf "${TARBALL}" -C "${R}/src" cart/pom.xml orders/pom.xml ui/pom.xml
chown -R ubuntu:ubuntu "${R}/src/cart" "${R}/src/orders" "${R}/src/ui"

echo "=== parent versions (after) ==="
for svc in cart orders ui; do
  echo "  ${svc}: $(sed -n '/<parent>/,/<\/parent>/p' "${R}/src/${svc}/pom.xml" | grep -o '<version>[^<]*' | head -n 1)"
done

echo "=== confirm the health import is back to the 3.5 package ==="
grep -rn 'actuate.health\|boot.health' "${R}/src/orders/src/main/java" | head -n 4

echo "=== rebuild all images ==="
cd "${R}/deployment-me" || exit 1
docker compose build > /root/rebuild-final.log 2>&1
echo "REBUILD_EXIT=$?"
grep -E '\[ERROR\]' /root/rebuild-final.log | head -n 10
docker images --format '{{.Repository}}:{{.Tag}} {{.Size}}' | grep '^deployment-me-'
