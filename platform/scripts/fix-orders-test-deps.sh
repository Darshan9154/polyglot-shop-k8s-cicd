#!/bin/bash
# fix-orders-test-deps.sh - restore version management for the test libraries that
# Spring Boot 4 no longer manages.
#
# Spring Boot 4.0.8 dropped dependency management for Testcontainers and REST Assured,
# so these three declarations now need versions. Testcontainers publishes a BOM, which
# is the tidy way to cover both testcontainers artifacts at once; rest-assured is a
# single artifact and gets an explicit version.
set -uo pipefail
R=/opt/polyglot-shop/source/polyglot-shop-k8s-cicd
POM="${R}/src/orders/pom.xml"

python3 - "${POM}" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()

# 1. Import the Testcontainers BOM into dependencyManagement.
if "testcontainers-bom" not in text:
    bom = """            <dependency>
                <groupId>org.testcontainers</groupId>
                <artifactId>testcontainers-bom</artifactId>
                <version>2.0.5</version>
                <type>pom</type>
                <scope>import</scope>
            </dependency>
"""
    # Insert inside the existing dependencyManagement > dependencies block, right after
    # its opening <dependencies> tag so it is imported with the others.
    m = re.search(r'<dependencyManagement>\s*<dependencies>', text)
    if not m:
        print("  ERROR: dependencyManagement/dependencies block not found")
        sys.exit(1)
    text = text[:m.end()] + "\n" + bom + text[m.end():]
    print("  testcontainers-bom 2.0.5 imported")

# 2. Give rest-assured an explicit version (no BOM covers it here).
if re.search(r'<artifactId>rest-assured</artifactId>', text) and not re.search(
        r'<artifactId>rest-assured</artifactId>\s*<version>', text):
    text = re.sub(
        r'(<artifactId>rest-assured</artifactId>)',
        r'\1\n            <version>6.1.0</version>',
        text,
        count=1,
    )
    print("  rest-assured pinned to 6.1.0")

open(path, "w").write(text)
PY

echo "=== resulting blocks ==="
grep -n -A3 'testcontainers-bom' "${POM}" | head -n 8
grep -n -A2 'rest-assured' "${POM}" | head -n 6

echo "=== rebuild orders ==="
cd "${R}/deployment-me" || exit 1
docker compose build orders > /root/build-orders5.log 2>&1
echo "BUILD_EXIT=$?"
grep -E '\[ERROR\].*(missing|Could not|could not|ERROR)' /root/build-orders5.log | head -n 12
tail -n 5 /root/build-orders5.log
