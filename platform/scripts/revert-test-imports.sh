#!/bin/bash
# revert-test-imports.sh - put the test imports back to their Spring Boot 3.5 locations.
#
# Why: the same half-applied state applied to test sources. Spring Boot 3.5.16 keeps
# @WebMvcTest in org.springframework.boot.test.autoconfigure.web.servlet and
# TestRestTemplate in org.springframework.boot.test.web.client; the Spring Boot 4 names
# (boot.webmvc.test.autoconfigure / boot.resttestclient) do not exist there.
set -uo pipefail
R=/opt/polyglot-shop/source/polyglot-shop-k8s-cicd

echo "=== files still holding SB4 test imports ==="
grep -rln 'boot\.resttestclient\|boot\.webmvc\.test\.autoconfigure' "${R}/src"/*/src 2>/dev/null || echo "(none)"

echo "=== reverting ==="
grep -rl 'boot\.resttestclient\|boot\.webmvc\.test\.autoconfigure' "${R}/src"/*/src 2>/dev/null | while read -r f; do
  sed -i \
    -e 's|org\.springframework\.boot\.resttestclient|org.springframework.boot.test.web.client|g' \
    -e 's|org\.springframework\.boot\.webmvc\.test\.autoconfigure|org.springframework.boot.test.autoconfigure.web.servlet|g' \
    "$f"
  echo "  $(echo "$f" | sed "s|${R}/src/||")"
done

echo "=== verify nothing SB4-specific remains in sources ==="
grep -rn 'boot\.health\.contributor\|boot\.resttestclient\|boot\.webmvc\.test\.autoconfigure' "${R}/src" 2>/dev/null | head -n 5 || echo "(clean)"

echo "=== rebuild all images ==="
cd "${R}/deployment-me" || exit 1
docker compose build > /root/rebuild-final3.log 2>&1
echo "REBUILD_EXIT=$?"
grep -E '\[ERROR\]' /root/rebuild-final3.log | head -n 8
docker images --format '{{.Repository}}:{{.Tag}} {{.Size}}' | grep '^deployment-me-'
