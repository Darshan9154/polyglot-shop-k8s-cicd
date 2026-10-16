#!/bin/bash
# reset-repo-clean.sh - return the working copy to the upstream commit.
#
# Why: after the stopped Spring Boot 4 migration, orders and ui no longer build, and my
# in-place edits (import rewrites, injected dependencies, version pins) accumulated. The
# migration is being abandoned rather than half-applied, so the reliable move is to put
# the tree back exactly where it started: commit a785cf0, the state that built, ran and
# passed the functional checks earlier in this project.
#
# cart, orders and ui all return to 3.5.16 as a consistent set. The measured result of
# the migration attempt is recorded separately in the project documentation.
set -uo pipefail
R=/opt/polyglot-shop/source/polyglot-shop-k8s-cicd
git config --global --add safe.directory "${R}" 2>/dev/null || true

echo "=== before ==="
git -C "${R}" status --porcelain | head -n 20

echo "=== hard reset to the upstream commit ==="
git -C "${R}" fetch --depth 1 origin || true
git -C "${R}" reset --hard a785cf0888e3770ef2e3edf1d64868edcc934e10
echo "HEAD_NOW=$(git -C "${R}" rev-parse --short HEAD)"

echo "=== after ==="
git -C "${R}" status --porcelain | head -n 10
echo "(empty above means the tree matches the commit exactly)"

echo "=== parent versions now ==="
for svc in cart orders ui; do
  v="$(sed -n '/<parent>/,/<\/parent>/p' "${R}/src/${svc}/pom.xml" | grep -o '<version>[^<]*' | head -n 1)"
  echo "  ${svc}: ${v}"
done

echo "=== rebuild all images ==="
cd "${R}/deployment-me" || exit 1
docker compose build > /root/rebuild-clean.log 2>&1
echo "REBUILD_EXIT=$?"
grep -E '\[ERROR\]' /root/rebuild-clean.log | head -n 8
tail -n 8 /root/rebuild-clean.log
