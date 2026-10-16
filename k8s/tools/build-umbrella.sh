#!/bin/bash
# build-umbrella.sh - resolve the umbrella chart's local subchart dependencies.
#
# Why `helm dependency build` and not `update`: build installs exactly the versions recorded
# in Chart.lock, so two people rendering the chart get the same result. `update` re-resolves
# the version constraints and can silently pull a different subchart version.
#
# Why the lock file matters for local path dependencies: the umbrella points at file://../cart
# and the siblings. Without a lock file, `helm template` on the umbrella renders an empty
# release — no error, just no workloads — which is a confusing failure to diagnose.
set -euo pipefail

K8S_DIR="${1:-/opt/polyglot-shop/k8s}"
UMBRELLA="${K8S_DIR}/app/umbrella"

cd "${UMBRELLA}"

if [ -f Chart.lock ]; then
  echo "lock file present; building from it"
  helm dependency build .
else
  echo "no lock file; resolving dependencies for the first time"
  helm dependency update .
fi

echo
echo "=== resolved dependencies ==="
ls -1 charts/ 2>/dev/null || echo "(no charts directory produced)"

echo
echo "=== rendered object count ==="
helm template shop . 2>/dev/null | grep -c '^kind:' || echo 0
