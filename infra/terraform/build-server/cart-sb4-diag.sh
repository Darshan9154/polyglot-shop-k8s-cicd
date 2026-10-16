#!/bin/bash
# cart-sb4-diag.sh - capture the full Maven failure for the Spring Boot 4 cart build.
set -uo pipefail
R=/opt/polyglot-shop/source/polyglot-shop-k8s-cicd
cd "${R}/deployment-me" || exit 1
docker compose build cart > /root/cart-sb4-build.log 2>&1
echo "BUILD_EXIT=$?"
echo "=== ERROR lines ==="
grep -nE '\[ERROR\]' /root/cart-sb4-build.log | head -n 40
echo "=== symbol/package mentions ==="
grep -nE 'cannot find symbol|package .* does not exist|does not exist|NoClassDefFound|UnsupportedClassVersion|incompatible' /root/cart-sb4-build.log | head -n 25
echo "=== log size ==="
wc -l /root/cart-sb4-build.log
