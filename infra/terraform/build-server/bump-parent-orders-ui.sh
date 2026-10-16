#!/bin/bash
# bump-parent-orders-ui.sh - move the remaining two services to Spring Boot 4.0.8.
#
# Why a targeted range edit: a plain global substitution is risky in these poms
# because other <version> tags exist (project version, dependencyManagement
# imports). Restricting the edit to the <parent> block changes only the parent.
set -uo pipefail
R=/opt/polyglot-shop/source/polyglot-shop-k8s-cicd

for svc in orders ui; do
  POM="${R}/src/${svc}/pom.xml"
  cp -a "${POM}" "/root/${svc}-pom.before-sb4"
  sed -i '/<parent>/,/<\/parent>/ s|<version>3\.5\.16</version>|<version>4.0.8</version>|' "${POM}"
  echo "=== ${svc} parent now ==="
  sed -n '/<parent>/,/<\/parent>/p' "${POM}" | grep -E 'artifactId|version'
done

echo "=== rebuild orders and ui ==="
cd "${R}/deployment-me" || exit 1
docker compose build orders ui > /root/build-orders-ui4.log 2>&1
echo "BUILD_EXIT=$?"
grep -E '\[ERROR\]' /root/build-orders-ui4.log | head -n 15
tail -n 6 /root/build-orders-ui4.log
