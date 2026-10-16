#!/bin/bash
# validate-all.sh - lint every chart, render it, and schema-validate every plain manifest.
#
# Why the full sweep rather than per-chart checks: a NetworkPolicy in one namespace can be
# invalid while every chart passes, and a label mismatch between an application chart and an
# infrastructure chart is not visible in either chart alone. Running everything together is
# what makes those cross-cutting mistakes visible.
set -uo pipefail
K8S_DIR=/opt/polyglot-shop/platform/charts
WORK=/tmp/all-validation
rm -rf "${WORK}" && mkdir -p "${WORK}"

APP_CHARTS="cart catalog checkout orders ui"
INFRA_CHARTS="mariadb postgresql redis rabbitmq dynamodb-local"

LINT_FAIL=0
VALID_FAIL=0

echo "=================================================="
echo "1. helm lint â€” every chart"
echo "=================================================="
for c in ${APP_CHARTS}; do
  if helm lint "${K8S_DIR}/app/${c}" >/dev/null 2>&1; then
    echo "  lint OK   : app/${c}"
  else
    echo "  lint FAIL : app/${c}"
    helm lint "${K8S_DIR}/app/${c}" 2>&1 | grep -i error | head -n 2
    LINT_FAIL=$((LINT_FAIL+1))
  fi
done
for c in ${INFRA_CHARTS}; do
  if helm lint "${K8S_DIR}/infra/${c}" >/dev/null 2>&1; then
    echo "  lint OK   : infra/${c}"
  else
    echo "  lint FAIL : infra/${c}"
    helm lint "${K8S_DIR}/infra/${c}" 2>&1 | grep -i error | head -n 2
    LINT_FAIL=$((LINT_FAIL+1))
  fi
done
for c in opentelemetry-collector jaeger loki; do
  if helm lint "${K8S_DIR}/observability/${c}" >/dev/null 2>&1; then
    echo "  lint OK   : observability/${c}"
  else
    echo "  lint FAIL : observability/${c}"
    helm lint "${K8S_DIR}/observability/${c}" 2>&1 | grep -i error | head -n 2
    LINT_FAIL=$((LINT_FAIL+1))
  fi
done

echo
echo "=================================================="
echo "2. helm template + kubeconform â€” rendered manifests"
echo "=================================================="
validate() {
  local label="$1" chartpath="$2"
  local chartname out res
  chartname="$(awk '/^name:/ {print $2; exit}' "${chartpath}/Chart.yaml")"
  out="${WORK}/${label//\//-}.yaml"
  # Why the release name is the chart name and not the path: the path contains a slash, and
  # Helm rejects it as an invalid release name. The bug is in this script, not in the chart,
  # but the symptom looked like a chart failure until the message was read.
  if ! helm template "${chartname}" "${chartpath}" > "${out}" 2>"${WORK}/err"; then
    echo "  render FAIL: ${label}"
    head -n 2 "${WORK}/err"
    VALID_FAIL=$((VALID_FAIL+1))
    return
  fi
  # Why -strict and -ignore-missing-schemas: strict rejects misspelled fields, and the
  # ignore flag prevents custom resources (ServiceMonitor, PrometheusRule) from being
  # reported as failures when their CRD schemas are not in the downloaded schema set.
  res="$(kubeconform -strict -summary -ignore-missing-schemas -kubernetes-version 1.31.0 "${out}" 2>&1 | tail -n 1)"
  echo "  ${label}: ${res}"
  if echo "${res}" | grep -q 'Invalid: [1-9]'; then
    VALID_FAIL=$((VALID_FAIL+1))
  fi
}

for c in ${APP_CHARTS}; do validate "app/${c}" "${K8S_DIR}/app/${c}"; done
for c in ${INFRA_CHARTS}; do validate "infra/${c}" "${K8S_DIR}/infra/${c}"; done
for c in opentelemetry-collector jaeger loki; do validate "observability/${c}" "${K8S_DIR}/observability/${c}"; done
# Why the umbrella is validated separately: it is a chart of charts, so templates the
# subcharts only once their dependencies are built. It is also the release shape that will
# actually be installed, so validating it catches a values path that no single chart exposes.
"${K8S_DIR}/tools/build-umbrella.sh" >/dev/null 2>&1 || true
if [ -f "${K8S_DIR}/app/umbrella/Chart.lock" ]; then
  validate "app/umbrella" "${K8S_DIR}/app/umbrella"
else
  echo "  app/umbrella: skipped (dependencies not built; run helm dependency build)"
fi

echo
echo "=================================================="
echo "3. plain manifests â€” bootstrap and observability extras"
echo "=================================================="
for f in "${K8S_DIR}"/bootstrap/*.yaml \
         "${K8S_DIR}"/observability/kube-prometheus-stack/servicemonitors.yaml \
         "${K8S_DIR}"/observability/kube-prometheus-stack/rules.yaml; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  res="$(kubeconform -strict -summary -ignore-missing-schemas -kubernetes-version 1.31.0 "$f" 2>&1 | tail -n 1)"
  echo "  ${name}: ${res}"
  if echo "${res}" | grep -q 'Invalid: [1-9]'; then
    VALID_FAIL=$((VALID_FAIL+1))
  fi
done

echo
echo "=================================================="
echo "4. cross-chart consistency checks"
echo "=================================================="
# Why this check: the application NetworkPolicies select infrastructure pods by the
# app.kubernetes.io/component value. If an infra chart's component value does not match what
# the application policy expects, traffic is silently blocked and the only symptom is a
# service that cannot reach its database.
echo "  component values declared by infrastructure charts:"
for c in ${INFRA_CHARTS}; do
  v="$(grep -E '^component:' "${K8S_DIR}/infra/${c}/values.yaml" | head -n 1 | awk '{print $2}')"
  echo "    ${c} -> ${v}"
done
echo "  components referenced by application egress rules:"
for c in ${APP_CHARTS}; do
  echo "    ${c}:"
  grep -oE 'app.kubernetes.io/component: [a-z0-9-]+' "${K8S_DIR}/app/${c}/values.yaml" 2>/dev/null | sort -u | sed 's/^/      /'
done

echo
echo "=================================================="
echo "SUMMARY  lint_failures=${LINT_FAIL}  validation_failures=${VALID_FAIL}"
echo "=================================================="
