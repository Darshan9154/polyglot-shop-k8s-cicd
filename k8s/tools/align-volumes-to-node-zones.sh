#!/bin/bash
# align-volumes-to-node-zones.sh - rebind StatefulSet volumes into the availability zone
# where worker nodes actually exist.
#
# Why this is necessary:
#
#   EBS volumes are created in one availability zone and cannot be moved. The charts use
#   WaitForFirstConsumer binding, so a volume is created in the zone of whichever node the pod
#   first schedules onto. When the node group was recreated, EKS placed both nodes in
#   eu-north-1c, but two volumes had already been created in eu-north-1b during an earlier node
#   generation. Those two pods then failed with
#
#     FailedScheduling: 0/3 nodes are available: 3 node(s) had volume node affinity conflict
#
#   Terraform cannot fix this: the node group takes a subnet list and EKS chooses the zone
#   within it. There is no configuration that pins a managed node group to a specific AZ.
#
# Why the claims are deleted rather than the nodes being replaced again:
#
#   Recreating the node group would be another eight-minute destroy plus create, and EKS could
#   just as easily place both nodes in one zone again. Deleting the two unsatisfiable claims
#   lets their StatefulSets create fresh claims, which bind in eu-north-1c where the nodes are.
#   The data in those two volumes is empty test data: the databases have never successfully
#   started, so nothing is lost.
#
# What this does NOT do: make the deployment zone-redundant. Both nodes remain in one AZ, so a
# zone failure takes the workload down. That is a recorded limitation of this test cluster,
# not something this script pretends to solve.
set -uo pipefail

NS=data
# Why these two specifically: they are the claims whose volumes are in the zone with no node.
# The other three (mariadb, redis, rabbitmq) are already in eu-north-1c and running.
TARGETS="postgresql dynamodb-local"

echo "=== node zones ==="
kubectl get nodes -o custom-columns='NAME:.metadata.name,ZONE:.metadata.labels.topology\.kubernetes\.io/zone' --no-headers

echo
echo "=== volumes and their zones before the change ==="
kubectl get pv -o custom-columns='AZ:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0],CLAIM:.spec.claimRef.name,STATUS:.status.phase' --no-headers | sort

for svc in ${TARGETS}; do
  echo
  echo "=== ${svc}: scaling down so the claim can be released ==="
  # Why scale to zero first: a StatefulSet will not release its volume claim while a pod
  # still references it. Deleting the claim while the pod exists leaves the pod in a state
  # where it holds a reference to a claim that no longer exists.
  kubectl -n "${NS}" scale statefulset "${svc}" --replicas=0 2>&1 | tail -n 1
  kubectl -n "${NS}" wait --for=delete pod "${svc}-0" --timeout=120s 2>&1 | tail -n 1

  echo "=== ${svc}: deleting the unsatisfiable claim ==="
  # Why the claim and not just the pod: the claim is bound to a PersistentVolume in the wrong
  # zone, and that binding is what the scheduler refuses. Removing the claim is what allows a
  # new volume to be provisioned in the zone where the nodes are.
  kubectl -n "${NS}" delete pvc "data-${svc}-0" --timeout=60s 2>&1 | tail -n 1

  echo "=== ${svc}: bringing it back up ==="
  kubectl -n "${NS}" scale statefulset "${svc}" --replicas=1 2>&1 | tail -n 1
done

echo
echo "=== waiting for the new claims to bind ==="
for i in $(seq 1 20); do
  pending="$(kubectl -n "${NS}" get pvc --no-headers 2>/dev/null | grep -c Pending || true)"
  echo "  poll ${i}: pending claims = ${pending}"
  [ "${pending}" = "0" ] && break
  sleep 15
done

echo
echo "=== volumes and zones after the change ==="
kubectl get pv -o custom-columns='AZ:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0],CLAIM:.spec.claimRef.name,STATUS:.status.phase' --no-headers | sort

echo
echo "=== pods in ${NS} ==="
kubectl -n "${NS}" get pods -o wide --no-headers
