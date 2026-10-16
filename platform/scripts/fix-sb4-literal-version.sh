#!/bin/bash
# fix-sb4-literal-version.sh - replace the inherited-version expression with 4.0.8.
#
# Why: ${project.parent.version} resolved to 3.5.16 rather than 4.0.8, because this
# repository has an aggregator pom at its root and the service builds resolve the
# parent differently than expected. The error was explicit:
#   spring-boot-resttestclient:jar:3.5.16 (absent)
# A literal version that matches the Spring Boot parent used by each pom removes the
# ambiguity. If the parent is bumped later, these three lines must be bumped too.
set -uo pipefail
R=/opt/polyglot-shop/source/polyglot-shop-k8s-cicd

for svc in orders ui cart; do
  POM="${R}/src/${svc}/pom.xml"
  before="$(grep -c 'project.parent.version' "${POM}" || true)"
  sed -i 's|<version>${project.parent.version}</version>|<version>4.0.8</version>|g' "${POM}"
  parent="$(grep -A2 'spring-boot-starter-parent' "${POM}" | grep -o '<version>[^<]*' | head -n 1)"
  echo "${svc}: replaced=${before} parent=${parent} newModules=$(grep -c '<version>4.0.8</version>' "${POM}")"
done

echo "=== rebuild orders and ui ==="
cd "${R}/deployment-me" || exit 1
docker compose build orders ui > /root/build-orders-ui3.log 2>&1
echo "BUILD_EXIT=$?"
grep -E '\[ERROR\]' /root/build-orders-ui3.log | head -n 12
tail -n 6 /root/build-orders-ui3.log
