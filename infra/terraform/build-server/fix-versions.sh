#!/bin/bash
# fix-versions.sh - for each image, show which packages need which version bump.
set -uo pipefail
LOGDIR=/var/log/retail-store-scans
for f in "${LOGDIR}"/trivy-*.json; do
  [ -f "$f" ] || continue
  python3 - "$f" <<'PY'
import json, sys, os, collections
path = sys.argv[1]
name = os.path.basename(path).replace("trivy-", "").replace(".json", "")
data = json.load(open(path))
rows = collections.defaultdict(lambda: {"cur": set(), "fix": set(), "c": 0, "h": 0})
for result in data.get("Results", []):
    for v in result.get("Vulnerabilities", []) or []:
        sev = v.get("Severity")
        if sev not in ("CRITICAL", "HIGH"):
            continue
        key = v.get("PkgName", "?")
        row = rows[key]
        row["cur"].add(v.get("InstalledVersion", "?"))
        row["fix"].add(v.get("FixedVersion", "none"))
        if sev == "CRITICAL":
            row["c"] += 1
        else:
            row["h"] += 1
print(f"--- {name} ---")
for pkg, row in sorted(rows.items(), key=lambda kv: (-kv[1]["c"], -kv[1]["h"]))[:6]:
    cur = ",".join(sorted(row["cur"]))
    fix = ",".join(sorted(row["fix"]))
    print(f"  {pkg} c={row['c']} h={row['h']} installed={cur} fixed_in={fix}")
# flag anything with no fix available at all
nofix = [(p, r) for p, r in rows.items() if all(x in ("none", "") for x in r["fix"])]
print(f"  packages_with_no_fix={len(nofix)}")
PY
done
