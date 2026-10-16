#!/bin/bash
# migrate-java-sb4-all.sh - apply the Spring Boot 4 moves to cart, orders and ui:
#  * health classes  -> org.springframework.boot.health.contributor  (spring-boot-health)
#  * @WebMvcTest     -> org.springframework.boot.webmvc.test.autoconfigure (spring-boot-webmvc-test)
#  * TestRestTemplate-> org.springframework.boot.resttestclient (spring-boot-resttestclient)
# Each package path was read from the real 4.0.8 jars, not inferred.
set -uo pipefail
R=/opt/polyglot-shop/source/polyglot-shop-k8s-cicd

for svc in cart orders ui; do
  echo "################ ${svc} ################"
  BASE="${R}/src/${svc}"
  POM="${BASE}/pom.xml"

  echo "=== rewrite source imports ==="
  grep -rl 'org\.springframework\.boot\.actuate\.health\|org\.springframework\.boot\.test\.web\.client\|org\.springframework\.boot\.test\.autoconfigure\.web\.servlet' "${BASE}/src" 2>/dev/null | while read -r f; do
    sed -i \
      -e 's|org\.springframework\.boot\.actuate\.health|org.springframework.boot.health.contributor|g' \
      -e 's|org\.springframework\.boot\.test\.web\.client|org.springframework.boot.resttestclient|g' \
      -e 's|org\.springframework\.boot\.test\.autoconfigure\.web\.servlet|org.springframework.boot.webmvc.test.autoconfigure|g' \
      "$f"
    echo "  $(basename "$f")"
  done

  echo "=== add the modules those packages live in ==="
  python3 - "${POM}" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
needed = [
    ("spring-boot-health", "org.springframework.boot"),
    ("spring-boot-webmvc-test", "org.springframework.boot"),
    ("spring-boot-resttestclient", "org.springframework.boot"),
]
added = []
for artifact, group in needed:
    if f"<artifactId>{artifact}</artifactId>" in text:
        continue
    dep = (
        "    <dependency>\n"
        f"      <groupId>{group}</groupId>\n"
        f"      <artifactId>{artifact}</artifactId>\n"
        "    </dependency>\n"
    )
    idx = text.rfind("</dependencies>")
    text = text[:idx] + dep + text[idx:]
    added.append(artifact)
open(path, "w").write(text)
print("  added:", ", ".join(added) if added else "nothing (already present)")
PY
done

echo "=== rebuild cart ==="
cd "${R}/deployment-me" || exit 1
docker compose build cart > /root/cart-sb4-build4.log 2>&1
echo "CART_BUILD_EXIT=$?"
grep -E '\[ERROR\].*(symbol|does not exist|ERROR)' /root/cart-sb4-build4.log | head -n 15
tail -n 4 /root/cart-sb4-build4.log
