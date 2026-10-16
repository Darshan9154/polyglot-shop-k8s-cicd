#!/bin/bash
# cart-sb4-fix.sh - apply the Spring Boot 4 package move for health indicators.
#
# Ground truth: Spring Boot 4 moved health code from org.springframework.boot.actuate.health
# into the new spring-boot-health module under org.springframework.boot.health
# (see spring-boot issue 48281, referenced from the 4.0 migration guide).
set -uo pipefail
R=/opt/polyglot-shop/source/polyglot-shop-k8s-cicd
SRC="${R}/src/cart/src/main/java"

echo "=== current health imports in cart ==="
grep -rn 'org.springframework.boot.actuate.health' "${SRC}" || echo "(none)"

echo "=== rewriting imports ==="
grep -rl 'org.springframework.boot.actuate.health' "${SRC}" | while read -r f; do
  sed -i 's|org\.springframework\.boot\.actuate\.health|org.springframework.boot.health|g' "$f"
  echo "  rewrote $(basename "$f")"
done

echo "=== imports after ==="
grep -rn 'org.springframework.boot.health' "${SRC}" || echo "(none found)"

echo "=== ensure the health module is on the classpath ==="
if grep -q 'spring-boot-starter-actuator' "${R}/src/cart/pom.xml"; then
  echo "actuator starter already declared (pulls spring-boot-health)"
else
  echo "adding spring-boot-health dependency"
  python3 - "${R}/src/cart/pom.xml" <<'PY'
import sys, re
path = sys.argv[1]
text = open(path).read()
dep = """    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-health</artifactId>
    </dependency>
"""
marker = "</dependencies>"
idx = text.rfind(marker)
text = text[:idx] + dep + text[idx:]
open(path, "w").write(text)
print("  inserted spring-boot-health before </dependencies>")
PY
fi

echo "=== rebuild cart ==="
cd "${R}/deployment-me" || exit 1
docker compose build cart > /root/cart-sb4-build2.log 2>&1
echo "BUILD_EXIT=$?"
grep -E '\[ERROR\].*(ERROR|symbol|does not exist)' /root/cart-sb4-build2.log | head -n 20
tail -n 6 /root/cart-sb4-build2.log
