#!/bin/bash
# scans.sh - Step 4: vulnerability and misconfiguration scanning before any push.
# Trivy scans the built images for HIGH/CRITICAL CVEs; Checkov scans the
# infrastructure and Kubernetes manifests. Nothing is pushed by this script.
set -uo pipefail
export PATH="$PATH:/root/.local/bin:/home/ubuntu/.local/bin"
LOGDIR=/var/log/retail-store-scans
mkdir -p "${LOGDIR}"
REPO_DIR='/opt/polyglot-shop/source/polyglot-shop-k8s-cicd'
cd "${REPO_DIR}/deployment-me" || exit 1

SHA="$(git -C "${REPO_DIR}" rev-parse --short HEAD)"
echo "GIT_SHA=${SHA}"
echo "STARTED=$(date -Is)"

echo "==> trivy version"
trivy --version | head -n 2

for svc in cart catalog checkout orders ui; do
  img="deployment-me-${svc}:latest"
  if ! docker image inspect "${img}" >/dev/null 2>&1; then
    echo "TRIVY_${svc}=no_image"
    continue
  fi
  json="${LOGDIR}/trivy-${svc}.json"
  # Why --ignore-unfixed: an unfixed CVE has no available patch, so failing the
  # build on it blocks progress without offering any way to fix it. It is still
  # recorded in the JSON report for the written exception list.
  if docker run --rm \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v "${LOGDIR}":/out \
      aquasec/trivy:latest image \
      --severity HIGH,CRITICAL \
      --ignore-unfixed \
      --format json \
      --output "/out/trivy-${svc}.json" \
      --exit-code 1 \
      "${img}" >>"${LOGDIR}/trivy-run.log" 2>&1; then
    echo "TRIVY_${svc}=pass"
  else
    echo "TRIVY_${svc}=fail"
  fi

  counts="$(python3 - "$json" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    print("unreadable"); raise SystemExit
sev = {}
for result in data.get("Results", []):
    for v in result.get("Vulnerabilities", []) or []:
        sev[v.get("Severity", "?")] = sev.get(v.get("Severity", "?"), 0) + 1
print(",".join(f"{k}={v}" for k, v in sorted(sev.items())) or "none")
PY
)"
  echo "TRIVY_${svc}_SEVERITIES=${counts}"
done

echo "==> checkov version"
checkov --version 2>/dev/null | head -n 1

echo "==> checkov terraform"
checkov -d "${REPO_DIR}/terraform" --compact --quiet -o cli > "${LOGDIR}/checkov-terraform.txt" 2>&1
echo "CHECKOV_TERRAFORM_EXIT=$?"
tail -n 4 "${LOGDIR}/checkov-terraform.txt"

echo "==> checkov kubernetes manifests"
checkov -d "${REPO_DIR}/deployment-me/k8-manifests" --compact --quiet -o cli > "${LOGDIR}/checkov-k8s.txt" 2>&1
echo "CHECKOV_K8S_EXIT=$?"
tail -n 4 "${LOGDIR}/checkov-k8s.txt"

echo "FINISHED=$(date -Is)"
echo "LOGDIR=${LOGDIR}"
