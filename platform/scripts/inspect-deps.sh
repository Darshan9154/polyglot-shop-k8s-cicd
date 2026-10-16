#!/bin/bash
# inspect-deps.sh - read the dependency declarations for the Node and Go services.
set -uo pipefail
R=/opt/polyglot-shop/source/polyglot-shop-k8s-cicd

echo "=== ui spring-boot parent ==="
grep -A3 'spring-boot-starter-parent' "${R}/src/ui/pom.xml" | head -n 5

echo "=== ui explicit thymeleaf ==="
grep -nE 'thymeleaf' "${R}/src/ui/pom.xml" | head -n 8

echo "=== checkout package.json dependencies ==="
python3 - "${R}/src/checkout/package.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print("dependencies:")
for k, v in (d.get("dependencies") or {}).items():
    print(f"  {k}={v}")
print("devDependencies:")
for k, v in (d.get("devDependencies") or {}).items():
    print(f"  {k}={v}")
PY

echo "=== catalog go.mod ==="
head -n 30 "${R}/src/catalog/go.mod"

echo "=== checkout Dockerfile ==="
cat "${R}/src/checkout/Dockerfile"
