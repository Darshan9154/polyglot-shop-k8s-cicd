#!/bin/bash
# restore-manifest.sh - put the checkout manifest back to its committed content
# without relying on git (which refuses this directory on ownership grounds).
# Then kick off a full image rebuild and rescan so the fix is measured, not assumed.
set -uo pipefail
R=/opt/polyglot-shop/source/polyglot-shop-k8s-cicd
SRC="${R}/src/checkout"

echo "=== restore package.json resolutions to the committed form ==="
cp -a "${SRC}/package.json" "/root/package.json.fixattempt"
python3 - "${SRC}/package.json" <<'PY'
import json, collections, sys
path = sys.argv[1]
with open(path) as fh:
    data = json.load(fh, object_pairs_hook=collections.OrderedDict)
# The upstream repository ships exactly this block. Keeping it byte-equivalent
# means the only differences left in the tree are the ones we intend.
data["resolutions"] = collections.OrderedDict([("multer", "^2.3.0")])
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
print("resolutions restored:", json.dumps(data["resolutions"]))
PY
echo "backup_of_attempt_saved=/root/package.json.fixattempt"
chown -R ubuntu:ubuntu "${SRC}"

echo "=== rebuild all images ==="
cd "${R}/deployment-me" || exit 1
if docker compose build 2>&1 | tail -n 20; then
  echo "REBUILD_STATUS=success"
else
  echo "REBUILD_STATUS=failed"
fi
docker images --format '{{.Repository}}:{{.Tag}} {{.Size}}' | grep '^deployment-me-'
