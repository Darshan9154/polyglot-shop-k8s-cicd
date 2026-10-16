#!/bin/bash
# deploy-app-and-infra.sh - deploy the application and its backing services to EKS.
#
# Why the application and infrastructure deploy before the observability stack: the worker
# nodes are t3.small instances with roughly 1.4 GiB allocatable each, because the EKS system
# daemonsets (VPC CNI, kube-proxy, EBS CSI node, CoreDNS) consume the rest. That is about
# 2.8 GiB for the whole cluster. Deploying the full observability stack on top of that would
# exhaust the node before there is any evidence about what the application actually needs, and
# the resulting Pending and Evicted pods would be impossible to attribute to one cause.
#
# Deploying in this order gives a real measurement: if the application fits, observability is
# added afterwards where there is room.
set -uo pipefail

K8S_DIR=/opt/polyglot-shop/platform/charts
CTX="${KUBE_CONTEXT:-}"
NS_APP=retail-store
NS_DATA=data

log() { echo; echo "=== $* ==="; }

log "1. bootstrap: namespaces, secret, default-deny NetworkPolicies"
kubectl apply -f "$(dirname "${K8S_DIR}")/bootstrap/" 2>&1 | tail -n 12

log "2. verify the namespaces exist before deploying into them"
kubectl get ns "${NS_APP}" "${NS_DATA}" --no-headers 2>&1

log "3. backing services (data namespace)"
# Why each is installed separately rather than as one release: they have different storage
# and lifecycle requirements, and a single release would make the StatefulSets share an
# uninstall. Installing them individually means the database can survive while the message
# broker is upgraded.
for c in mariadb postgresql redis rabbitmq dynamodb-local; do
  echo "--- installing ${c} ---"
  helm upgrade --install "${c}" "${K8S_DIR}/infra/${c}" \
    --namespace "${NS_DATA}" \
    --wait --timeout 8m 2>&1 | tail -n 4
  echo "exit=$?"
done

log "4. application services (retail-store namespace)"
# Why the umbrella chart: it installs all five services as one release. The subchart
# dependencies were resolved at build time by build-umbrella.sh.
helm upgrade --install shop "${K8S_DIR}/app/umbrella" \
  --namespace "${NS_APP}" \
  --wait --timeout 12m 2>&1 | tail -n 8
echo "app_exit=$?"

log "5. workloads"
kubectl -n "${NS_DATA}" get statefulset,pods -o wide 2>&1 | head -n 20
kubectl -n "${NS_APP}" get deployment,pods -o wide 2>&1 | head -n 20

log "6. any pending or unhealthy pods"
kubectl -n "${NS_DATA}" get pods --field-selector=status.phase!=Running 2>&1 | head -n 10
kubectl -n "${NS_APP}" get pods --field-selector=status.phase!=Running 2>&1 | head -n 10

log "7. node pressure"
kubectl get nodes -o custom-columns='NAME:.metadata.name,MEM_ALLOC:.status.allocatable.memory,CONDITIONS:.status.conditions[-1].type' 2>&1
