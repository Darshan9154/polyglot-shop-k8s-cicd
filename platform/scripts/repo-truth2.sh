#!/bin/bash
# repo-truth2.sh - same checks with the git ownership guard resolved first.
set -uo pipefail
R=/opt/polyglot-shop/source/polyglot-shop-k8s-cicd

# The previous run failed on "dubious ownership" because the repo is owned by ubuntu
# while this script runs as root. Declaring the directory safe removes that guard.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=safe.directory
export GIT_CONFIG_VALUE_0="${R}"

echo "=== remote ==="
git -C "${R}" remote -v
echo "=== HEAD ==="
git -C "${R}" rev-parse HEAD
echo "=== history ==="
git -C "${R}" log --oneline -3
echo "=== tracked files ==="
git -C "${R}" ls-files | wc -l
echo "=== dirty files ==="
git -C "${R}" status --short | head -n 8
echo "=== does this instance reach the GitHub repo? ==="
timeout 25 git ls-remote --heads origin | head -n 3
echo "LS_REMOTE_EXIT=$?"
echo "=== existing workflows in the repo ==="
ls -la "${R}/.github/workflows"
echo "=== kubernetes manifests available for EKS ==="
ls "${R}/deployment-me/k8-manifests"
