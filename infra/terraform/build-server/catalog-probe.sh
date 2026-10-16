#!/bin/bash
# catalog-probe.sh - find the real catalog route and confirm whether products load.
set -uo pipefail
REPO_DIR='/opt/polyglot-shop/source/polyglot-shop-k8s-cicd'
cd "${REPO_DIR}/deployment-me" || exit 1

echo "==> candidate catalog routes"
for path in /catalogue /catalogue/ /products /api/catalogue /health /; do
  code="$(curl -s -o /tmp/probe.out -w '%{http_code}' --max-time 15 "http://localhost:8081${path}")"
  size="$(wc -c < /tmp/probe.out)"
  echo "catalog${path} -> http=${code} bytes=${size}"
done

echo "==> catalogue body (first 400 bytes)"
curl -s --max-time 15 http://localhost:8081/catalogue/ | head -c 400
echo

echo "==> product rows in the catalog database"
docker compose exec -T catalog-db mysql -uroot -p"${DB_PASSWORD:-}" -N -e 'SELECT COUNT(*) FROM catalogdb.products;' 2>/dev/null \
  || docker compose exec -T catalog-db sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e "SHOW DATABASES; SELECT COUNT(*) FROM catalogdb.products;"' 2>&1 | head -n 8

echo "==> catalog application errors in last 5 minutes"
docker compose logs catalog --since 5m --no-color 2>&1 | grep -iE 'error|fail' | tail -n 8 || echo "(none)"

echo "==> ui to catalog reachability"
docker compose exec -T ui sh -c 'curl -s -o /dev/null -w "ui_to_catalog=%{http_code}\n" --max-time 10 http://catalog:8080/catalogue/' 2>&1
