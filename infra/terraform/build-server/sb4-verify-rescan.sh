#!/bin/bash
# sb4-verify-rescan.sh - confirm the effective Spring Boot parent per service, then
# rescan the three rebuilt Java images.
set -uo pipefail
R=/opt/polyglot-shop/source/polyglot-shop-k8s-cicd
LOGDIR=/var/log/retail-store-scans/after2
mkdir -p "${LOGDIR}"

echo "=== effective spring-boot parent version per service ==="
for svc in cart orders ui; do
  v="$(python3 - "${R}/src/${svc}/pom.xml" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'<artifactId>spring-boot-starter-parent</artifactId>\s*<version>([^<]+)</version>', text)
print(m.group(1) if m else "NOT-FOUND")
PY
)"
  echo "  ${svc}: ${v}"
done

echo "=== rescan rebuilt Java images ==="
cd "${R}/deployment-me" || exit 1
for svc in cart orders ui; do
  img="deployment-me-${svc}:latest"
  docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${LOGDIR}":/out \
    aquasec/trivy:latest image --severity HIGH,CRITICAL --ignore-unfixed \
    --format json --output "/out/trivy-${svc}.json" --exit-code 1 "${img}" \
    >>"${LOGDIR}/rescan.log" 2>&1
  echo "  TRIVY_${svc}_exit=$?"
done

python3 - <<'PY'
import json, glob
print(f"{'image':10} {'CRITICAL':>8} {'HIGH':>6}")
tot_c = tot_h = 0
for f in sorted(glob.glob("/var/log/retail-store-scans/after2/trivy-*.json")):
    name = f.split("trivy-")[-1].replace(".json", "")
    data = json.load(open(f))
    c = h = 0
    for r in data.get("Results", []):
        for v in r.get("Vulnerabilities", []) or []:
            if v.get("Severity") == "CRITICAL": c += 1
            elif v.get("Severity") == "HIGH": h += 1
    tot_c += c; tot_h += h
    print(f"{name:10} {c:>8} {h:>6}")
print(f"{'TOTAL':10} {tot_c:>8} {tot_h:>6}")
print()
for f in sorted(glob.glob("/var/log/retail-store-scans/after2/trivy-*.json")):
    name = f.split("trivy-")[-1].replace(".json", "")
    data = json.load(open(f))
    rows = set()
    for r in data.get("Results", []):
        for v in r.get("Vulnerabilities", []) or []:
            if v.get("Severity") == "CRITICAL":
                rows.add("{} {} {}->{}".format(v.get("VulnerabilityID"), v.get("PkgName"),
                                              v.get("InstalledVersion"), v.get("FixedVersion") or "none"))
    for row in sorted(rows):
        print(f"  {name}: {row}")
PY
