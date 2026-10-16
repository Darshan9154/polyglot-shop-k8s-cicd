#!/bin/bash
# cart-sb4-fix2.sh - use the real Spring Boot 4 package and add the module.
#
# Ground truth from the actual spring-boot-health-4.0.8.jar contents:
#   Health / HealthIndicator / AbstractHealthIndicator live in
#   org.springframework.boot.health.contributor
# (not org.springframework.boot.health, and not ...health.contributor.Health).
# The actuator starter does not bring the module transitively, so it is declared.
set -uo pipefail
R=/opt/polyglot-shop/source/polyglot-shop-k8s-cicd
SRC="${R}/src/cart/src/main/java"
POM="${R}/src/cart/pom.xml"

echo "=== rewrite to the verified package ==="
grep -rl 'org\.springframework\.boot\.health' "${SRC}" | while read -r f; do
  sed -i 's|org\.springframework\.boot\.health\.Health|org.springframework.boot.health.contributor.Health|g;
          s|org\.springframework\.boot\.health\.HealthIndicator|org.springframework.boot.health.contributor.HealthIndicator|g' "$f"
  echo "  rewrote $(basename "$f")"
done
grep -n 'import org.springframework.boot.health' "${SRC}/com/amazon/sample/carts/chaos/ChaosHealthIndicator.java"

echo "=== declare spring-boot-health explicitly ==="
python3 - "${POM}" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
if "spring-boot-health" in text:
    print("  already declared")
else:
    dep = """    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-health</artifactId>
    </dependency>
"""
    marker = "</dependencies>"
    idx = text.rfind(marker)
    text = text[:idx] + dep + text[idx:]
    open(path, "w").write(text)
    print("  inserted spring-boot-health")
PY
grep -n -A2 'spring-boot-health' "${POM}"

echo "=== rebuild cart ==="
cd "${R}/deployment-me" || exit 1
docker compose build cart > /root/cart-sb4-build3.log 2>&1
echo "BUILD_EXIT=$?"
grep -E '\[ERROR\].*(symbol|does not exist|ERROR)' /root/cart-sb4-build3.log | head -n 15
tail -n 5 /root/cart-sb4-build3.log
