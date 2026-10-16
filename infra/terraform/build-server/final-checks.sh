#!/bin/bash
# final-checks.sh - confirm toolchain state and explain the compose "degraded" flag.
set -uo pipefail
export PATH="$PATH:/root/.local/bin:/home/ubuntu/.local/bin"
REPO_DIR='/opt/polyglot-shop/source/polyglot-shop-k8s-cicd'
cd "${REPO_DIR}/deployment-me" || exit 1

echo "==> tool presence"
for t in docker git aws kubectl helm terraform trivy checkov eksctl; do
  if command -v "$t" >/dev/null 2>&1; then echo "${t}=installed"; else echo "${t}=MISSING"; fi
done

echo "==> rabbitmq listeners"
docker compose exec -T rabbitmq sh -c 'rabbitmq-diagnostics -q ping 2>&1 | tail -n 2' 2>&1 | tail -n 3
curl -s -o /dev/null -w 'rabbitmq_mgmt_http=%{http_code}\n' --max-time 10 http://localhost:15672/ || true

echo "==> healthchecks declared in compose"
grep -c 'healthcheck:' docker-compose.yml
echo "services without a healthcheck:"
awk '/^  [a-z].*:$/{svc=$1} /healthcheck:/{hc[svc]=1} END{for (s in hc) print s}' docker-compose.yml

echo "==> container restart counts"
docker compose ps --format '{{.Service}} restarts={{.ExitCode}} state={{.State}}'
