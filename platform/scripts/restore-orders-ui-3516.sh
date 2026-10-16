#!/bin/bash
# restore-orders-ui-3516.sh - return orders and ui to the known-good Spring Boot 3.5.16
# baseline after the Spring Boot 4 migration was stopped.
#
# Why this is the right move: cart migrated cleanly (CRITICAL 6 -> 0), but orders and
# ui were left half-migrated and do not build at all. A repository that builds with
# known findings is strictly better than one that cannot build, so the two services go
# back to the last state that built and ran. cart keeps its successful migration.
#
# The SB4-only additions (spring-boot-health, spring-boot-webmvc-test,
# spring-boot-resttestclient, testcontainers-bom, the 4.0.8 pins) are removed because
# those artifacts do not exist for Spring Boot 3.5.16. The import rewrites stay: the new
# package names remain valid in 3.5.16, which still ships both locations.
set -uo pipefail
R=/opt/polyglot-shop/source/polyglot-shop-k8s-cicd

for svc in orders ui; do
  POM="${R}/src/${svc}/pom.xml"
  echo "=== restoring ${svc} pom ==="
  python3 - "${POM}" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()

# Parent back to 3.5.16 (only inside the parent block).
text, n_parent = re.subn(
    r'(<parent>.*?<version>)4\.0\.8(</version>)',
    r'\g<1>3.5.16\g<2>',
    text,
    flags=re.S,
)
print(f"  parent restored: {n_parent}")

# Remove the migration-only dependency blocks.
removed = 0
for artifact in ("spring-boot-health", "spring-boot-webmvc-test", "spring-boot-resttestclient"):
    pattern = re.compile(
        r'\s*<dependency>\s*<groupId>org\.springframework\.boot</groupId>\s*'
        r'<artifactId>' + re.escape(artifact) + r'</artifactId>\s*'
        r'(<version>[^<]*</version>\s*)?</dependency>'
    )
    text, n = pattern.subn("", text)
    removed += n
print(f"  spring-boot-4 modules removed: {removed}")

# Remove the Testcontainers BOM import added during the migration.
pattern = re.compile(
    r'\s*<dependency>\s*<groupId>org\.testcontainers</groupId>\s*'
    r'<artifactId>testcontainers-bom</artifactId>\s*<version>[^<]*</version>\s*'
    r'<type>pom</type>\s*<scope>import</scope>\s*</dependency>'
)
text, n_bom = pattern.subn("", text)
print(f"  testcontainers-bom removed: {n_bom}")

# Remove the explicit 2.0.5 / 4.0.8 / 6.1.0 pins that only the migration needed.
text, n_pins = re.subn(r'<version>2\.0\.5</version>\s*', '', text)
text, n_r = re.subn(r'<version>6\.1\.0</version>\s*', '', text)
text, n_408 = re.subn(r'<version>4\.0\.8</version>\s*(?=</dependency>)', '', text)
print(f"  pins removed: testcontainers={n_pins} rest-assured={n_r} sb4={n_408}")

open(path, "w").write(text)
PY
  echo "  parent block now:"
  sed -n '/<parent>/,/<\/parent>/p' "${POM}" | grep -E 'version'
done

echo "=== rebuild orders and ui ==="
cd "${R}/deployment-me" || exit 1
docker compose build orders ui > /root/restore-build.log 2>&1
echo "BUILD_EXIT=$?"
grep -E '\[ERROR\]' /root/restore-build.log | head -n 10
tail -n 6 /root/restore-build.log
