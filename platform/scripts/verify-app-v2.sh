#!/bin/bash
# verify-app-v2.sh - rerun the functional checks against the correct catalog routes.
set -uo pipefail
REPO_DIR='/opt/polyglot-shop/source/polyglot-shop-k8s-cicd'
cd "${REPO_DIR}/deployment-me" || exit 1

echo "==> catalog routes"
for path in /catalog/products /catalog/size /catalog/tags /health; do
  code="$(curl -s -o /tmp/p.out -w '%{http_code}' --max-time 15 "http://localhost:8081${path}")"
  echo "catalog${path} -> http=${code} bytes=$(wc -c < /tmp/p.out)"
done

echo "==> catalog size body"
curl -s --max-time 15 http://localhost:8081/catalog/size
echo

echo "==> first products"
curl -s --max-time 15 http://localhost:8081/catalog/products | head -c 300
echo

echo "==> ui home page contains product markup?"
curl -s --max-time 20 http://localhost:8888/ -o /tmp/ui.html
echo "ui_bytes=$(wc -c < /tmp/ui.html)"
grep -o -iE 'product|cart|store' /tmp/ui.html | sort | uniq -c | head -n 5

echo "==> ui health through the load path"
curl -s -o /dev/null -w 'ui_health=%{http_code}\n' --max-time 15 http://localhost:8888/actuator/health

echo "==> component health recap"
for p in 8888 8081 8082 8083 8085; do
  curl -s -o /dev/null -w "port${p}=%{http_code}\n" --max-time 10 "http://localhost:${p}/actuator/health" 2>/dev/null || true
done
curl -s -o /dev/null -w 'port8081_health=%{http_code}\n' --max-time 10 http://localhost:8081/health
curl -s -o /dev/null -w 'port8085_health=%{http_code}\n' --max-time 10 http://localhost:8085/health
