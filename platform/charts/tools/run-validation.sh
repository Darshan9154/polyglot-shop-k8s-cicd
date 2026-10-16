#!/bin/bash
# run-validation.sh - render each chart and validate the rendered manifests.
set -uo pipefail
K8S_DIR=/opt/polyglot-shop/platform/charts
for c in cart catalog orders checkout ui; do
  echo "--- ${c} ---"
  if helm template "${c}" "${K8S_DIR}/app/${c}" > "/tmp/v-${c}.yaml" 2>"/tmp/v-${c}.err"; then
    kubeconform -strict -summary -ignore-missing-schemas -kubernetes-version 1.31.0 "/tmp/v-${c}.yaml" 2>&1 | tail -n 2
  else
    echo "RENDER_FAIL"
    head -n 3 "/tmp/v-${c}.err"
  fi
done
