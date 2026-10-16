#!/bin/bash
# revert-health-imports.sh - put the health imports back to the Spring Boot 3.5 package.
#
# Why: the POMs were restored to 3.5.16, but the Java imports had been rewritten to the
# Spring Boot 4 module (org.springframework.boot.health.contributor), which does not exist
# in 3.5.16. Restoring the poms without reverting the imports creates exactly that
# mismatch: "package org.springframework.boot.health.contributor does not exist".
# The 3.5.16 location is org.springframework.boot.actuate.health.
set -uo pipefail
R=/opt/polyglot-shop/source/polyglot-shop-k8s-cicd

echo "=== files needing revert ==="
grep -rln 'org\.springframework\.boot\.health' "${R}/src"/*/src 2>/dev/null || echo "(none)"

echo "=== reverting ==="
grep -rl 'org\.springframework\.boot\.health' "${R}/src"/*/src 2>/dev/null | while read -r f; do
  sed -i 's|org\.springframework\.boot\.health\.contributor|org.springframework.boot.actuate.health|g' "$f"
  echo "  $(echo "$f" | sed "s|${R}/src/||")"
done

echo "=== imports now ==="
grep -rn 'actuate\.health\|boot\.health' "${R}/src"/*/src 2>/dev/null | head -n 8

echo "=== rebuild all images ==="
cd "${R}/deployment-me" || exit 1
docker compose build > /root/rebuild-final2.log 2>&1
echo "REBUILD_EXIT=$?"
grep -E '\[ERROR\]' /root/rebuild-final2.log | head -n 8
tail -n 6 /root/rebuild-final2.log
