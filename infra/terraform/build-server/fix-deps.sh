#!/bin/bash
# fix-deps.sh - remediate the scan findings at source, before any rebuild.
# Changes are limited to dependency declarations; git is the rollback handle.
set -uo pipefail
R=/opt/polyglot-shop/source/polyglot-shop-k8s-cicd
cd "${R}" || exit 1
echo "HEAD_BEFORE=$(git rev-parse --short HEAD)"
echo "PRE_CHANGE_DIRTY_LINES=$(git status --porcelain | wc -l)"

echo "== 1. spring boot patch 3.5.5 -> 3.5.16 (cart, orders, ui) =="
for s in cart orders ui; do
  sed -i 's|<version>3\.5\.5</version>|<version>3.5.16</version>|' "${R}/src/${s}/pom.xml"
  echo "  ${s}: $(grep -A2 spring-boot-starter-parent "${R}/src/${s}/pom.xml" | grep -o '<version>[^<]*' | head -n 1)"
done

echo "== 2. orders: pin amqp-client past the vulnerable 5.25.0 =="
if ! grep -q 'rabbit-amqp-client.version' "${R}/src/orders/pom.xml"; then
  sed -i 's|<mapstruct.version>1.6.3</mapstruct.version>|<mapstruct.version>1.6.3</mapstruct.version>\n        <rabbit-amqp-client.version>5.34.0</rabbit-amqp-client.version>|' "${R}/src/orders/pom.xml"
fi
grep -n 'rabbit-amqp-client.version' "${R}/src/orders/pom.xml"

echo "== 3. catalog: bump vulnerable Go modules =="
echo "  go.mod before:"
grep -E 'google.golang.org/grpc|golang.org/x/(crypto|net)' "${R}/src/catalog/go.mod"
docker run --rm -v "${R}/src/catalog":/app -w /app golang:1.23-bookworm sh -c '
set -e
go get google.golang.org/grpc@v1.79.3
go get golang.org/x/crypto@v0.52.0
go get golang.org/x/net@v0.53.0
go mod tidy
' 2>&1 | tail -n 8
echo "  go.mod after:"
grep -E 'google.golang.org/grpc|golang.org/x/(crypto|net)' "${R}/src/catalog/go.mod"
chown -R ubuntu:ubuntu "${R}/src/catalog"

echo "== 4. checkout: current resolved versions of the flagged packages =="
for p in protobufjs form-data proxy-addr minimatch brace-expansion fast-uri; do
  v="$(python3 - "${R}/src/checkout/yarn.lock" "$p" <<'PY'
import re, sys
lock, pkg = sys.argv[1], sys.argv[2]
text = open(lock, encoding="utf-8", errors="replace").read()
vs = sorted(set(re.findall(r'^"?%s@[^:]*:\n\s+version "?([^"\n]+)"?' % re.escape(pkg), text, re.M)))
print(",".join(vs) if vs else "not-in-lockfile")
PY
)"
  echo "  ${p}: ${v}"
done

echo "== diff summary =="
git -C "${R}" status --porcelain
