#!/bin/bash
# rescan.sh - re-run Trivy over the rebuilt images and report severity counts.
set -uo pipefail
LOGDIR=/var/log/retail-store-scans
mkdir -p "${LOGDIR}/after"
cd /opt/polyglot-shop/source/polyglot-shop-k8s-cicd/deployment-me || exit 1

for svc in cart catalog checkout orders ui; do
  img="deployment-me-${svc}:latest"
  json="${LOGDIR}/after/trivy-${svc}.json"
  if docker run --rm \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v "${LOGDIR}/after":/out \
      aquasec/trivy:latest image \
      --severity HIGH,CRITICAL --ignore-unfixed --format json \
      --output "/out/trivy-${svc}.json" --exit-code 1 "${img}" \
      >>"${LOGDIR}/rescan.log" 2>&1; then
    echo "TRIVY_${svc}=pass"
  else
    echo "TRIVY_${svc}=fail"
  fi
  python3 - "${json}" "${svc}" <<'PY'
import json, sys, collections, os
path, name = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path))
except Exception as exc:
    print(f"  {name}: unreadable {exc}"); raise SystemExit
crit = collections.Counter(); high = collections.Counter()
for result in data.get("Results", []):
    for v in result.get("Vulnerabilities", []) or []:
        pkg = v.get("PkgName", "?")
        if v.get("Severity") == "CRITICAL":
            crit[pkg] += 1
        elif v.get("Severity") == "HIGH":
            high[pkg] += 1
print(f"  {name}: CRITICAL={sum(crit.values())} HIGH={sum(high.values())}")
if crit:
    print("    top critical:", ", ".join(f"{p}({c})" for p, c in crit.most_common(4)))
PY
done
