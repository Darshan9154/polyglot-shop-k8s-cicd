#!/bin/bash
set -e

NAMESPACE="retail-store"
MANIFEST_DIR="./k8-manifests"

echo "🚀 Starting Retail Store Sample App Deployment"

# Step 1: Delete old namespace
echo "👉 Step 1: Delete old namespace (if exists)"
kubectl delete namespace $NAMESPACE --ignore-not-found || true

echo "⏳ Waiting for namespace '$NAMESPACE' to terminate (if exists)..."
while kubectl get namespace $NAMESPACE >/dev/null 2>&1; do
  echo "   Namespace $NAMESPACE still terminating..."
  sleep 5
done
echo "✅ Namespace $NAMESPACE deleted successfully (or did not exist)."

# Step 2: Create namespace
echo "👉 Step 2: Create namespace"
kubectl apply -f $MANIFEST_DIR/00-namespace.yaml
echo "✅ Namespace created."

# Step 3: Apply secrets
echo "👉 Step 3: Apply secrets"
kubectl apply -f $MANIFEST_DIR/01-secrets.yaml
echo "✅ Secrets applied."

# Step 4: Deploy RabbitMQ (StatefulSet)
echo "👉 Step 4: Deploy RabbitMQ"
kubectl apply -f $MANIFEST_DIR/10-rabbitmq.yaml
kubectl -n $NAMESPACE rollout status statefulset/rabbitmq --timeout=300s
echo "✅ RabbitMQ ready."

# Step 5: Deploy Postgres (orders-db) (StatefulSet)
echo "👉 Step 5: Deploy Postgres (orders-db)"
kubectl apply -f $MANIFEST_DIR/22-postgres.yaml
kubectl -n $NAMESPACE rollout status statefulset/orders-db --timeout=300s
echo "✅ Postgres ready."

# Step 6: Deploy Redis (checkout-redis) (StatefulSet)
echo "👉 Step 6: Deploy Redis (checkout-redis)"
kubectl apply -f $MANIFEST_DIR/30-redis.yaml
kubectl -n $NAMESPACE rollout status statefulset/checkout-redis --timeout=300s
echo "✅ Redis ready."

# Step 7: Deploy MariaDB (catalog-db) (StatefulSet)
echo "👉 Step 7: Deploy MariaDB (catalog-db)"
kubectl apply -f $MANIFEST_DIR/31-mariadb.yaml
kubectl -n $NAMESPACE rollout status statefulset/catalog-db --timeout=300s
echo "✅ MariaDB ready."

# Step 8: Deploy DynamoDB Local (carts-db) (Deployment)
echo "👉 Step 8: Deploy DynamoDB Local (carts-db)"
kubectl apply -f $MANIFEST_DIR/42-carts-db.yaml
kubectl -n $NAMESPACE rollout status deployment/carts-db --timeout=300s
echo "✅ DynamoDB Local ready."

# Step 9: Deploy Catalog (Deployment)
echo "👉 Step 9: Deploy Catalog service"
kubectl apply -f $MANIFEST_DIR/40-catalog.yaml
kubectl -n $NAMESPACE rollout status deployment/catalog --timeout=300s
echo "✅ Catalog ready."

# Step 10: Deploy Orders (Deployment)
echo "👉 Step 10: Deploy Orders service"
kubectl apply -f $MANIFEST_DIR/41-orders.yaml
kubectl -n $NAMESPACE rollout status deployment/orders --timeout=300s
echo "✅ Orders ready."

# Step 11: Deploy Cart (Deployment)
echo "👉 Step 11: Deploy Cart service"
kubectl apply -f $MANIFEST_DIR/42-cart.yaml
kubectl -n $NAMESPACE rollout status deployment/cart --timeout=300s
echo "✅ Cart ready."

# Step 12: Deploy Checkout (Deployment)
echo "👉 Step 12: Deploy Checkout service"
kubectl apply -f $MANIFEST_DIR/43-checkout.yaml
kubectl -n $NAMESPACE rollout status deployment/checkout --timeout=300s
echo "✅ Checkout ready."

# Step 13: Deploy UI (Deployment)
echo "👉 Step 13: Deploy UI service"
kubectl apply -f $MANIFEST_DIR/50-ui.yaml
kubectl -n $NAMESPACE rollout status deployment/ui --timeout=300s
echo "✅ UI ready."

echo "🎉 Deployment complete!"
echo "👉 To watch pods:   kubectl -n $NAMESPACE get pods -w"
echo "👉 To access UI:    kubectl -n $NAMESPACE get svc ui"
