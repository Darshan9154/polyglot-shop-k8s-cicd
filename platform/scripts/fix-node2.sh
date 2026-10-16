#!/bin/bash
# fix-node2.sh - correct the resolution keys and regenerate the lockfile.
#
# Why this second attempt: yarn 1 reads a resolutions key of the form
# "<pkg>@<range>". Writing "minimatch@3" made yarn search for a package literally
# named "minimatch" at range "3", producing
# "Couldn't find any versions for minimatch that matches 3@3.1.4". The range must
# be a real semver range such as ^3.
set -uo pipefail
SRC=/opt/polyglot-shop/source/polyglot-shop-k8s-cicd/src/checkout
cd "${SRC}" || exit 1

python3 - "${SRC}/package.json" <<'PY'
import json, collections, sys
path = sys.argv[1]
with open(path) as fh:
    data = json.load(fh, object_pairs_hook=collections.OrderedDict)
res = collections.OrderedDict()
res["multer"] = "^2.3.0"
res.update(collections.OrderedDict([
    ("protobufjs@>=7.4.0 <7.6.0", "7.5.5"),
    ("form-data@>=2.3.3 <3.0.0", "2.5.6"),
    ("form-data@>=4.0.0 <5.0.0", "4.0.6"),
    ("proxy-addr@^2.0.0", "2.0.8"),
    ("minimatch@^3.0.0", "3.1.4"),
    ("minimatch@^5.0.0", "5.1.8"),
    ("minimatch@^9.0.0", "9.0.7"),
    ("minimatch@^10.0.0", "10.2.3"),
    ("brace-expansion@^1.0.0", "1.1.19"),
    ("brace-expansion@^2.0.0", "2.1.6"),
    ("fast-uri@^3.0.0", "3.1.7"),
]))
data["resolutions"] = res
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
print("resolutions:")
for k, v in res.items():
    print(f"  {k} -> {v}")
PY

echo "=== yarn install (classic, write-enabled) ==="
docker run --rm -v "${SRC}":/app -w /app node:20-alpine \
  sh -c 'yarn install --non-interactive 2>&1 | tail -n 8' 2>&1 | tail -n 12

chown -R ubuntu:ubuntu "${SRC}"

echo "=== resolved versions after regenerating ==="
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

echo "=== lockfile line count (was ~15k?) ==="
wc -l "${SRC}/yarn.lock"
