#!/bin/bash
# validate-charts.sh - render every chart and validate the result against Kubernetes schemas.
#
# Why this runs on the instance: kubeconform is a Go binary, already installed here, and
# it validates offline. `kubectl --dry-run=client` is not a substitute — it still tries
# to reach a cluster, so it cannot validate anything before the cluster exists.
#
# Why validate the rendered output rather than only linting the chart: helm lint checks
# the chart's structure. It does not prove that the YAML the templates produce is valid
# Kubernetes. A chart can lint cleanly and still render an invalid object.
set -uo pipefail
K8S_DIR="${1:-/opt/polyglot-shop/k8s}"
WORK=/tmp/chart-validation
rm -rf "${WORK}" && mkdir -p "${WORK}"

echo "=== charts found ==="
find "${K8S_DIR}/app" -name Chart.yaml | sort

PASS=0; FAIL=0
for chartdir in $(find "${K8S_DIR}/app" -mindepth 1 -maxdepth 1 -type d | sort); do
  name="$(basename "${chartdir}")"
  out="${WORK}/${name}.yaml"

  if ! helm template "${name}" "${chartdir}" > "${out}" 2>"${WORK}/${name}.err"; then
    echo "RENDER_FAIL: ${name}"
    head -n 3 "${WORK}/${name}.err"
    FAIL=$((FAIL+1))
    continue
  fi

  # Why -strict: it rejects unknown or misspelled fields instead of ignoring them, which
  # is how a typo like `readinessProbe` under the wrong level is caught.
  # Why the schema locations: the default schema set does not cover every version, and
  # -ignore-missing-schemas keeps a missing CRD schema from being reported as a failure.
  if kubeconform -strict -summary \
       -ignore-missing-schemas \
       -kubernetes-version 1.31.0 \
       "${out}" 2>&1 | tail -n 2; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
  fi
done

echo
echo "=== per-chart object inventory ==="
for f in "${WORK}"/*.yaml; do
  [ -f "$f" ] || continue
  n="$(basename "$f" .yaml)"
  kinds="$(grep -c '^kind:' "$f" 2>/dev/null || echo 0)"
  echo "  ${n}: ${kinds} objects"
done

echo
echo "VALIDATION_SUMMARY pass=${PASS} fail=${FAIL}"
