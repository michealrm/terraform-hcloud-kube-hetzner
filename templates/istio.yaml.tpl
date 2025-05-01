apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: istio-base
  namespace: kube-system
spec:
  repo: https://istio-release.storage.googleapis.com/charts
  chart: base
  version: ${version}
  targetNamespace: ${target_namespace}
  bootstrap: true
---
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: istiod
  namespace: kube-system
spec:
  repo: https://istio-release.storage.googleapis.com/charts
  chart: istiod
  version: ${version}
  targetNamespace: ${target_namespace}
  bootstrap: true
  valuesContent: |-
${values}
---
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: istio-ingress
  namespace: kube-system
spec:
  repo: https://istio-release.storage.googleapis.com/charts
  chart: gateway
  version: ${version}
  targetNamespace: ${target_namespace}
  valuesContent: |-
    # Configure Istio Gateway for load balancer
    service:
      annotations:
        load-balancer.hetzner.cloud/name: "${load_balancer_name}"
        load-balancer.hetzner.cloud/use-private-ip: "true"
        load-balancer.hetzner.cloud/disable-private-ingress: "true"
        load-balancer.hetzner.cloud/location: "${load_balancer_location}"
        load-balancer.hetzner.cloud/type: "${load_balancer_type}"
        load-balancer.hetzner.cloud/uses-proxyprotocol: "${uses_proxy_protocol}"
        ${lb_hostname_annotation}

    # Autoscaling configuration
    autoscaling:
      enabled: ${autoscaling}
      minReplicas: ${replica_count}
      maxReplicas: ${max_replica_count}

    # Deployment configuration
    replicaCount: ${replica_count}
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 2000m
        memory: 1024Mi
