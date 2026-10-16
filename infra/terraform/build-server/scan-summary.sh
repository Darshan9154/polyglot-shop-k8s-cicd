#!/bin/bash
# scan-summary.sh - summarise the scan results without dumping whole reports.
set -uo pipefail
LOGDIR=/var/log/retail-store-scans
echo "==> overall result lines"
grep -E 'GIT_SHA|TRIVY_[a-z]+=|TRIVY_[a-z]+_SEVERITIES|CHECKOV_.*_EXIT' /root/scans.out

echo "==> top vulnerable packages per image"
for f in "${LOGDIR}"/trivy-*.json; do
  [ -f "$f" ] || continue
  python3 - "$f" <<'PY'
import json, sys, collections, os
path = sys.argv[1]
name = os.path.basename(path).replace("trivy-", "").replace(".json", "")
try:
    data = json.load(open(path))
except Exception as exc:
    print(f"{name}: unreadable ({exc})")
    raise SystemExit
crit = collections.Counter()
high = collections.Counter()
for result in data.get("Results", []):
    for v in result.get("Vulnerabilities", []) or []:
        pkg = v.get("PkgName", "?")
        if v.get("Severity") == "CRITICAL":
            crit[pkg] += 1
        elif v.get("Severity") == "HIGH":
            high[pkg] += 1
top_crit = ", ".join(f"{p}({c})" for p, c in crit.most_common(4)) or "none"
top_high = ", ".join(f"{p}({c})" for p, c in high.most_common(4)) or "none"
print(f"{name}: critical_total={sum(crit.values())} top={top_crit}")
print(f"{name}: high_total={sum(high.values())} top={top_high}")
PY
done

echo "==> OS base images and their severity counts inside the tarballs"
docker images --format '{{.Repository}}:{{.Tag}}' | grep '^deployment-me-' | while read -r img; do
  base="$(docker image inspect "$img" --format '{{json .Config.Labels}}' 2>/dev/null | head -c 200)"
  echo "${img} labels=${base}"
done

echo "==> checkov terraform summary"
tail -n 12 "${LOGDIR}/checkov-terraform.txt" 2>/dev/null || echo "(missing)"

echo "==> checkov kubernetes summary"
tail -n 12 "${LOGDIR}/checkov-k8s.txt" 2>/dev/null || echo "(missing)"

echo "==> checkov failing checks (kubernetes, unique)"
grep -oE 'Check: CKV[A-Z0-9_]+' "${LOGDIR}/checkov-k8s.txt" 2>/dev/null | sort | uniq -c | sort -rn | head -n 12 || true

echo "==> checkov failing checks (terraform, unique)"
grep -oE 'Check: CKV[A-Z0-9_]+' "${LOGDIR}/checkov-terraform.txt" 2>/dev/null | sort | uniq -c | sort -rn | head -n 12 || true

echo "==> report files"
ls -la "${LOGDIR}"
