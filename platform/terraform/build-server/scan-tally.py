import json
import glob

print(f"{'image':10} {'CRITICAL':>8} {'HIGH':>6}")
tot_c = tot_h = 0
for f in sorted(glob.glob("/var/log/retail-store-scans/after/trivy-*.json")):
    name = f.split("trivy-")[-1].replace(".json", "")
    data = json.load(open(f))
    c = h = 0
    for result in data.get("Results", []):
        for v in result.get("Vulnerabilities", []) or []:
            if v.get("Severity") == "CRITICAL":
                c += 1
            elif v.get("Severity") == "HIGH":
                h += 1
    tot_c += c
    tot_h += h
    print(f"{name:10} {c:>8} {h:>6}")
print(f"{'TOTAL':10} {tot_c:>8} {tot_h:>6}")
print()
print("remaining CRITICAL findings:")
for f in sorted(glob.glob("/var/log/retail-store-scans/after/trivy-*.json")):
    name = f.split("trivy-")[-1].replace(".json", "")
    data = json.load(open(f))
    rows = []
    for result in data.get("Results", []):
        for v in result.get("Vulnerabilities", []) or []:
            if v.get("Severity") == "CRITICAL":
                rows.append(
                    "{} {} {}->{}".format(
                        v.get("VulnerabilityID"),
                        v.get("PkgName"),
                        v.get("InstalledVersion"),
                        v.get("FixedVersion") or "none",
                    )
                )
    for row in sorted(set(rows)):
        print(f"  {name}: {row}")
