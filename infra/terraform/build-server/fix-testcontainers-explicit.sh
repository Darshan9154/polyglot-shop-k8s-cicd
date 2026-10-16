#!/bin/bash
# fix-testcontainers-explicit.sh - final orders fix: explicit versions instead of a BOM.
#
# The imported testcontainers-bom did not take effect inside this POM's own
# dependencyManagement (the resolver still reported the versions as missing), so the
# two artifacts get explicit versions. This is the last attempt on this cascade; if a
# further distinct resolution error appears, the migration stops and is reported with
# the exact remaining blocker rather than chased further.
set -uo pipefail
R=/opt/polyglot-shop/source/polyglot-shop-k8s-cicd

for svc in orders ui; do
  POM="${R}/src/${svc}/pom.xml"
  python3 - "${POM}" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
changed = []
for artifact in ("junit-jupiter", "postgresql"):
    pattern = re.compile(
        r'(<groupId>org\.testcontainers</groupId>\s*<artifactId>' + re.escape(artifact) + r'</artifactId>)'
        r'(\s*)(?!\s*<version>)'
    )
    text, n = pattern.subn(r'\1\2<version>2.0.5</version>\n            ', text)
    if n:
        changed.append(f"{artifact}({n})")
open(path, "w").write(text)
print(f"  {path.split('/')[-2]}: explicit versions for {', '.join(changed) if changed else 'none needed'}")
PY
done

echo "=== rebuild orders ==="
cd "${R}/deployment-me" || exit 1
docker compose build orders > /root/build-orders6.log 2>&1
echo "BUILD_EXIT=$?"
grep -E '\[ERROR\]' /root/build-orders6.log | head -n 12
tail -n 5 /root/build-orders6.log
