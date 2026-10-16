#!/bin/bash
# fix-node4.sh - restore the committed manifest, then refresh the dependency tree.
#
# Why the earlier run did nothing: `git checkout -- src/checkout/...` failed with
# "dubious ownership" because the repo is owned by ubuntu while the script runs as
# root, so the broken resolutions block stayed in package.json and the install
# failed on it again. The safe.directory entry must be added before any git
# command in a root-run script.
set -uo pipefail
R=/opt/polyglot-shop/source/polyglot-shop-k8s-cicd
SRC="${R}/src/checkout"

git config --global --add safe.directory "${R}"
echo "=== restore committed state ==="
git -C "${R}" checkout -- src/checkout/package.json src/checkout/yarn.lock
git -C "${R}" status --porcelain | head -n 10
python3 - "${SRC}/package.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print("resolutions now:", json.dumps(d.get("resolutions")))
PY

echo "=== refresh within declared ranges ==="
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

echo "=== changed files ==="
git -C "${R}" status --porcelain
