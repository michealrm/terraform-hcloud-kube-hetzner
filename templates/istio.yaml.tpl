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
