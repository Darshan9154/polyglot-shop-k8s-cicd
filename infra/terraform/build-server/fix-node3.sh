#!/bin/bash
# fix-node3.sh - third and final Node approach.
#
# History: custom `resolutions` keys with ranges were rejected by yarn 1
# ("Couldn't find any versions for X that matches RANGE@VERSION"), and a plain
# package-name key cannot express "only within major 1". So instead of
# hand-pinning, this refreshes the tree using the caret ranges the manifest
# already declares, which is the mechanism the project itself relies on.
set -uo pipefail
SRC=/opt/polyglot-shop/source/polyglot-shop-k8s-cicd/src/checkout
cd "${SRC}" || exit 1

echo "=== restart from the committed manifest and lockfile ==="
git -C /opt/polyglot-shop/source/polyglot-shop-k8s-cicd checkout -- src/checkout/package.json src/checkout/yarn.lock
grep -n -A3 '"resolutions"' "${SRC}/package.json"
wc -l "${SRC}/yarn.lock"

echo "=== resolve latest versions still satisfying the declared ranges ==="
docker run --rm -v "${SRC}":/app -w /app node:20-alpine \
  sh -c 'yarn install --non-interactive 2>&1 | tail -n 6' 2>&1 | tail -n 8

chown -R ubuntu:ubuntu "${SRC}"

echo "=== resolved versions now ==="
for p in protobufjs form-data proxy-addr minimatch brace-expansion fast-uri multer; do
  v="$(python3 - "${SRC}/yarn.lock" "$p" <<'PY'
import re, sys
lock, pkg = sys.argv[1], sys.argv[2]
text = open(lock, encoding="utf-8", errors="replace").read()
vs = sorted(set(re.findall(r'^"?%s@[^:]*:\n\s+version "?([^"\n]+)"?' % re.escape(pkg), text, re.M)))
print(",".join(vs) if vs else "absent")
PY
)"
  echo "  ${p}: ${v}"
done
echo "=== lockfile lines after refresh ==="
wc -l "${SRC}/yarn.lock"
echo "=== changed files ==="
git -C /opt/polyglot-shop/source/polyglot-shop-k8s-cicd status --porcelain
