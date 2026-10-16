#!/bin/bash
# fix-node.sh - pin patched versions of the flagged transitive npm packages.
#
# Why resolutions and not `yarn upgrade`: the checkout image runs classic yarn 1
# (confirmed from the build image), whose lockfile is v1, and this project
# already uses `resolutions` for multer. Re-resolving the whole tree could pull
# unrelated majors; targeted pins change only the flagged packages.
#
# Why versions stay inside their existing major: brace-expansion 1.x exposes a
# different API surface from 2.x+, and minimatch has several major lines in the
# tree. Pinning across majors risks breaking the build, so each pin stays in the
# same major line we observed in the current lockfile.
set -uo pipefail
SRC=/opt/polyglot-shop/source/polyglot-shop-k8s-cicd/src/checkout
cd "${SRC}" || exit 1

python3 - "${SRC}/package.json" <<'PY'
import json, collections, sys
path = sys.argv[1]
with open(path) as fh:
    data = json.load(fh, object_pairs_hook=collections.OrderedDict)
res = data.get("resolutions") or collections.OrderedDict()
res.update(collections.OrderedDict([
    ("protobufjs@>=7.4.0 <7.6.0", "7.5.5"),
    ("form-data@>=2.3.3 <3.0.0", "2.5.6"),
    ("form-data@>=4.0.0 <5.0.0", "4.0.6"),
    ("proxy-addr", "2.0.8"),
    ("minimatch@3", "3.1.4"),
    ("minimatch@5", "5.1.8"),
    ("minimatch@9", "9.0.7"),
    ("minimatch@10", "10.2.3"),
    ("brace-expansion@1", "1.1.19"),
    ("brace-expansion@2", "2.1.6"),
    ("fast-uri@3", "3.1.7"),
]))
data["resolutions"] = res
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
print("resolutions written:")
for k, v in res.items():
    print(f"  {k} -> {v}")
PY

echo "=== regenerating lockfile (non-frozen, write-enabled mount) ==="
docker run --rm -v "${SRC}":/app -w /app -e COREPACK_ENABLE_DOWNLOAD_PROMPT=0 node:20-alpine \
  sh -c 'yarn install --non-interactive 2>&1 | tail -n 6' 2>&1 | tail -n 10

chown -R ubuntu:ubuntu "${SRC}"
echo "=== resolved versions now in the lockfile ==="
for p in protobufjs form-data proxy-addr minimatch brace-expansion fast-uri; do
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
