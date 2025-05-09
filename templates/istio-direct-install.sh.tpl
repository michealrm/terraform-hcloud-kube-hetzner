#!/bin/bash
set -e

ISTIO_VERSION="${version}"
NAMESPACE="${target_namespace}"
VALUES_FILE="/tmp/istio-values.yaml"

# Ensure namespace exists
echo "Ensuring namespace $NAMESPACE exists..."
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Create values file
cat > $VALUES_FILE << EOL
${values}
EOL

# Install Istio CRDs
echo "Installing Istio CRDs..."
kubectl apply --server-side -f https://raw.githubusercontent.com/istio/istio/refs/tags/$ISTIO_VERSION/manifests/charts/base/files/crd-all.gen.yaml

# Install istiod directly using helm
echo "Installing istiod directly with helm..."
kubectl create -n $NAMESPACE secret generic istio-values --from-file=values.yaml=$VALUES_FILE --dry-run=client -o yaml | kubectl apply -f -

# Apply istiod using helm
echo "Using helm to install istiod..."
kubectl delete job -n kube-system helm-install-istiod 2>/dev/null || true
kubectl create job -n kube-system helm-install-istiod --image=rancher/klipper-helm:v0.8.0 -- helm install istiod https://istio-release.storage.googleapis.com/charts/istiod-$ISTIO_VERSION.tgz -n $NAMESPACE -f $VALUES_FILE --wait --timeout 5m

echo "Waiting for istiod to be ready..."
# Wait with a timeout for istiod deployment
timeout 300s bash -c "until kubectl get deployment/istiod -n $NAMESPACE; do echo 'Waiting for istiod deployment...'; sleep 5; done"
kubectl wait --for=condition=available --timeout=300s deployment/istiod -n $NAMESPACE

# Install Istio Gateway
echo "Installing Istio Gateway..."
cat > /tmp/ingress-values.yaml << EOL
service:
  type: LoadBalancer
  name: istio-ingressgateway
  annotations:
    load-balancer.hetzner.cloud/name: "${load_balancer_name}"
    load-balancer.hetzner.cloud/use-private-ip: "true"
    load-balancer.hetzner.cloud/disable-private-ingress: "true"
    load-balancer.hetzner.cloud/disable-public-network: "${load_balancer_disable_public_network}"
    load-balancer.hetzner.cloud/ipv6-disabled: "${load_balancer_disable_ipv6}"
    load-balancer.hetzner.cloud/location: "${load_balancer_location}"
    load-balancer.hetzner.cloud/type: "${load_balancer_type}"
    load-balancer.hetzner.cloud/uses-proxyprotocol: "${uses_proxy_protocol}"
    load-balancer.hetzner.cloud/algorithm-type: "${load_balancer_algorithm_type}"
    load-balancer.hetzner.cloud/health-check-interval: "${load_balancer_health_check_interval}"
    load-balancer.hetzner.cloud/health-check-timeout: "${load_balancer_health_check_timeout}"
    load-balancer.hetzner.cloud/health-check-retries: "${load_balancer_health_check_retries}"
    load-balancer.hetzner.cloud/hostname: "${lb_hostname}"
autoscaling:
  enabled: ${autoscaling}
  minReplicas: ${replica_count}
  maxReplicas: ${max_replica_count}
replicaCount: ${replica_count}
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 2000m
    memory: 1024Mi
EOL

# Apply gateway using helm
echo "Using helm to install gateway..."
kubectl delete job -n kube-system helm-install-gateway 2>/dev/null || true
kubectl create job -n kube-system helm-install-gateway --image=rancher/klipper-helm:v0.8.0 -- helm install istio-ingress https://istio-release.storage.googleapis.com/charts/gateway-$ISTIO_VERSION.tgz -n $NAMESPACE -f /tmp/ingress-values.yaml --wait --timeout 5m

echo "Waiting for gateway to be ready..."
# Wait with a timeout for gateway deployment
timeout 300s bash -c "until kubectl get deployment/istio-ingressgateway -n $NAMESPACE; do echo 'Waiting for gateway deployment...'; sleep 5; done"
kubectl wait --for=condition=available --timeout=300s deployment/istio-ingressgateway -n $NAMESPACE

echo "Istio installation complete!"

# Check loadbalancer status
echo "Checking loadbalancer status..."
kubectl get service/istio-ingressgateway -n $NAMESPACE

echo "Istio direct installation completed successfully"