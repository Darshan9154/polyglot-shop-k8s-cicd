#!/bin/bash
# inspect-yarn.sh - locate the checkout lockfile that --frozen-lockfile needs.
set -uo pipefail
R=/opt/polyglot-shop/source/polyglot-shop-k8s-cicd
echo "=== lockfiles anywhere in checkout ==="
find "${R}/src/checkout" -maxdepth 2 -name 'yarn.lock' -o -maxdepth 2 -name 'package-lock.json' 2>/dev/null | head
echo "=== repo root yarn files ==="
ls -la "${R}" | grep -iE 'yarn|lock' || echo "(none)"
echo "=== .yarnrc.yml ==="
cat "${R}/.yarnrc.yml" 2>/dev/null || echo "(none)"
echo "=== checkout package.json packageManager + workspaces ==="
python3 - "${R}/src/checkout/package.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for k in ("packageManager", "workspaces", "scripts"):
    print(f"{k} = {d.get(k)}")
PY
echo "=== root package.json workspaces ==="
python3 - "${R}/package.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print("packageManager =", d.get("packageManager"))
print("workspaces =", d.get("workspaces"))
PY
echo "=== yarn availability on host ==="
yarn --version 2>/dev/null || echo "(yarn not installed on host)"
