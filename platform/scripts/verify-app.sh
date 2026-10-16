#!/bin/bash
# verify-app.sh - functional checks against the running Compose stack.
set -uo pipefail
REPO_DIR='/opt/polyglot-shop/source/polyglot-shop-k8s-cicd'
cd "${REPO_DIR}/deployment-me" || exit 1

echo "==> build/up status lines"
grep -hE 'BUILD_STATUS|UP_STATUS' /root/resume-build.out /root/compose-up.out 2>/dev/null || true

echo "==> container states"
docker compose ps --format '{{.Service}}={{.State}}/{{.Health}}'

echo "==> ui root"
curl -s -o /dev/null -w 'ui_http_status=%{http_code}\n' --max-time 20 http://localhost:8888/
curl -s -o /dev/null -w 'ui_health_status=%{http_code}\n' --max-time 20 http://localhost:8888/actuator/health

echo "==> catalog api"
curl -s --max-time 20 http://localhost:8081/catalogue | head -c 300
echo
curl -s -o /dev/null -w 'catalog_health_status=%{http_code}\n' --max-time 20 http://localhost:8081/health

echo "==> cart api via ui port"
curl -s -o /dev/null -w 'cart_health_status=%{http_code}\n' --max-time 20 http://localhost:8082/actuator/health
curl -s -o /dev/null -w 'orders_health_status=%{http_code}\n' --max-time 20 http://localhost:8083/actuator/health
curl -s -o /dev/null -w 'checkout_health_status=%{http_code}\n' --max-time 20 http://localhost:8085/health

echo "==> recent errors in logs"
docker compose logs --tail 40 --no-color 2>&1 | grep -iE 'error|exception|fatal' | head -n 12 || echo "(no error lines in the last 40 log lines)"
