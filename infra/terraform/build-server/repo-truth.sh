#!/bin/bash
# repo-truth.sh - settle whether the repository exists on GitHub or only on this instance.
#
# It checks the instance's clone (remotes, history, cleanliness) and also asks GitHub
# directly whether the repository is reachable, so the answer does not depend on my
# assumptions.
set -uo pipefail
R=/opt/polyglot-shop/source/polyglot-shop-k8s-cicd

echo "=== remote configuration ==="
git -C "${R}" remote -v

echo "=== local commit ==="
git -C "${R}" rev-parse HEAD

echo "=== recent history ==="
git -C "${R}" log --oneline -3 2>&1

echo "=== working tree state ==="
git -C "${R}" status --short | head -n 10
echo "(empty above = matches the commit)"

echo "=== committed file count ==="
git -C "${R}" ls-files | wc -l

echo "=== can this instance reach the GitHub repo? ==="
timeout 25 git ls-remote --heads origin 2>&1 | head -n 5
echo "LS_REMOTE_EXIT=$?"

echo "=== does the repo exist at all (HTTP check) ==="
for url in "https://github.com/Darshan9154/polyglot-shop-k8s-cicd" "https://github.com/aws-containers/retail-store-sample-app"; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$url")"
  echo "  ${url} -> HTTP ${code}"
done

echo "=== deployment files that a pipeline would need ==="
ls -la "${R}/.github" 2>/dev/null || echo "(no .github directory)"
ls -la "${R}/deployment-me" | head -n 20
