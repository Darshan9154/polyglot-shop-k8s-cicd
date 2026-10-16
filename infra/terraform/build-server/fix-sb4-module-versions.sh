#!/bin/bash
# fix-sb4-module-versions.sh - give the new Spring Boot 4 modules explicit versions.
#
# Why this is needed: orders (unlike cart) imports spring-boot-dependencies inside
# its own <dependencyManagement>. That local import wins over the parent's, and the
# modules added by the migration are not managed by the version that gets picked up,
# producing "'dependencies.dependency.version' for ... is missing".
#
# Why ${project.parent.version}: it resolves to the Spring Boot parent version
# (4.0.8), so these stay in step whenever the parent is bumped, instead of being
# hard-coded a second time.
set -uo pipefail
R=/opt/polyglot-shop/source/polyglot-shop-k8s-cicd

for svc in orders ui; do
  POM="${R}/src/${svc}/pom.xml"
  echo "=== ${svc} ==="
  python3 - "${POM}" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
for artifact in ("spring-boot-health", "spring-boot-webmvc-test", "spring-boot-resttestclient"):
    # Only touch the dependency block for this artifact, and only if it has no version.
    pattern = re.compile(
        r'(<dependency>\s*<groupId>org\.springframework\.boot</groupId>\s*'
        r'<artifactId>' + re.escape(artifact) + r'</artifactId>)(\s*)(</dependency>)'
    )
    text, n = pattern.subn(
        r'\1\2<version>${project.parent.version}</version>\n    \3', text
    )
    print(f"  {artifact}: {n} version(s) added")
open(path, "w").write(text)
PY
  grep -n -A3 -E 'spring-boot-(health|webmvc-test|resttestclient)' "${POM}" | head -n 14
done

echo "=== rebuild orders and ui ==="
cd "${R}/deployment-me" || exit 1
docker compose build orders ui > /root/build-orders-ui2.log 2>&1
echo "BUILD_EXIT=$?"
grep -E '\[ERROR\]' /root/build-orders-ui2.log | head -n 12
tail -n 5 /root/build-orders-ui2.log
