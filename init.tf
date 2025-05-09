resource "hcloud_load_balancer" "cluster" {
  count = local.has_external_load_balancer ? 0 : 1
  name  = local.load_balancer_name

  load_balancer_type = var.load_balancer_type
  location           = var.load_balancer_location
  labels             = local.labels
  delete_protection  = var.enable_delete_protection.load_balancer

  algorithm {
    type = var.load_balancer_algorithm_type
  }

  lifecycle {
    ignore_changes = [
      # Ignore changes to hcloud-ccm/service-uid label that is managed by the CCM.
      labels["hcloud-ccm/service-uid"],
    ]
  }
}

resource "hcloud_load_balancer_network" "cluster" {
  count = local.has_external_load_balancer ? 0 : 1

  load_balancer_id = hcloud_load_balancer.cluster.*.id[0]
  subnet_id        = hcloud_network_subnet.agent.*.id[0]
}

resource "hcloud_load_balancer_target" "cluster" {
  count = local.has_external_load_balancer ? 0 : 1

  depends_on       = [hcloud_load_balancer_network.cluster]
  type             = "label_selector"
  load_balancer_id = hcloud_load_balancer.cluster.*.id[0]
  label_selector   = join(",", [for k, v in merge(local.labels, local.labels_control_plane_node, local.labels_agent_node) : "${k}=${v}"])
  use_private_ip   = true
}

locals {
  first_control_plane_ip = coalesce(
    module.control_planes[keys(module.control_planes)[0]].ipv4_address,
    module.control_planes[keys(module.control_planes)[0]].ipv6_address,
    module.control_planes[keys(module.control_planes)[0]].private_ipv4_address
  )
}

resource "null_resource" "first_control_plane" {
  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = local.first_control_plane_ip
    port           = var.ssh_port
  }

  # Generating k3s master config file
  provisioner "file" {
    content = yamlencode(
      merge(
        {
          node-name                   = module.control_planes[keys(module.control_planes)[0]].name
          token                       = local.k3s_token
          cluster-init                = true
          disable-cloud-controller    = true
          disable-kube-proxy          = var.disable_kube_proxy
          disable                     = local.disable_extras
          kubelet-arg                 = local.kubelet_arg
          kube-controller-manager-arg = local.kube_controller_manager_arg
          flannel-iface               = local.flannel_iface
          node-ip                     = module.control_planes[keys(module.control_planes)[0]].private_ipv4_address
          advertise-address           = module.control_planes[keys(module.control_planes)[0]].private_ipv4_address
          node-taint                  = local.control_plane_nodes[keys(module.control_planes)[0]].taints
          node-label                  = local.control_plane_nodes[keys(module.control_planes)[0]].labels
          cluster-cidr                = var.cluster_ipv4_cidr
          service-cidr                = var.service_ipv4_cidr
          cluster-dns                 = var.cluster_dns_ipv4
        },
        lookup(local.cni_k3s_settings, var.cni_plugin, {}),
        var.use_control_plane_lb ? {
          tls-san = concat([hcloud_load_balancer.control_plane.*.ipv4[0], hcloud_load_balancer_network.control_plane.*.ip[0]], var.additional_tls_sans)
          } : {
          tls-san = concat([local.first_control_plane_ip], var.additional_tls_sans)
        },
        local.etcd_s3_snapshots,
        var.control_planes_custom_config,
        (local.control_plane_nodes[keys(module.control_planes)[0]].selinux == true ? { selinux = true } : {})
      )
    )

    destination = "/tmp/config.yaml"
  }

  # Install k3s server
  provisioner "remote-exec" {
    inline = local.install_k3s_server
  }

  # Upon reboot start k3s and wait for it to be ready to receive commands
  provisioner "remote-exec" {
    inline = [
      "systemctl start k3s",
      # prepare the needed directories
      "mkdir -p /var/post_install /var/user_kustomize",
      # wait for k3s to become ready
      <<-EOT
      timeout 120 bash <<EOF
        until systemctl status k3s > /dev/null; do
          systemctl start k3s
          echo "Waiting for the k3s server to start..."
          sleep 2
        done
        until [ -e /etc/rancher/k3s/k3s.yaml ]; do
          echo "Waiting for kubectl config..."
          sleep 2
        done
        until [[ "\$(kubectl get --raw='/readyz' 2> /dev/null)" == "ok" ]]; do
          echo "Waiting for the cluster to become ready..."
          sleep 2
        done
      EOF
      EOT
    ]
  }

  depends_on = [
    hcloud_network_subnet.control_plane
  ]
}

# Needed for rancher setup
resource "random_password" "rancher_bootstrap" {
  count   = length(var.rancher_bootstrap_password) == 0 ? 1 : 0
  length  = 48
  special = false
}

# This is where all the setup of Kubernetes components happen
resource "null_resource" "kustomization" {
  triggers = {
    # Redeploy helm charts when the underlying values change
    helm_values_yaml = join("---\n", [
      local.traefik_values,
      local.nginx_values,
      local.haproxy_values,
      local.istio_values,
      local.calico_values,
      local.cilium_values,
      local.longhorn_values,
      local.csi_driver_smb_values,
      local.cert_manager_values,
      local.rancher_values,
      local.hetzner_csi_values
    ])
    # Redeploy when versions of addons need to be updated
    versions = join("\n", [
      coalesce(var.initial_k3s_channel, "N/A"),
      coalesce(var.install_k3s_version, "N/A"),
      coalesce(var.cluster_autoscaler_version, "N/A"),
      coalesce(var.hetzner_ccm_version, "N/A"),
      coalesce(var.hetzner_csi_version, "N/A"),
      coalesce(var.kured_version, "N/A"),
      coalesce(var.calico_version, "N/A"),
      coalesce(var.cilium_version, "N/A"),
      coalesce(var.traefik_version, "N/A"),
      coalesce(var.nginx_version, "N/A"),
      coalesce(var.haproxy_version, "N/A"),
      coalesce(var.istio_version, "N/A"),
    ])
    options = join("\n", [
      for option, value in local.kured_options : "${option}=${value}"
    ])
  }

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = local.first_control_plane_ip
    port           = var.ssh_port
  }

  # Upload kustomization.yaml, containing Hetzner CSI & CSM, as well as kured.
  provisioner "file" {
    content     = local.kustomization_backup_yaml
    destination = "/var/post_install/kustomization.yaml"
  }

  # Upload traefik ingress controller config
  provisioner "file" {
    content = templatefile(
      "${path.module}/templates/traefik_ingress.yaml.tpl",
      {
        version          = var.traefik_version
        values           = indent(4, trimspace(local.traefik_values))
        target_namespace = local.ingress_controller_namespace
    })
    destination = "/var/post_install/traefik_ingress.yaml"
  }

  # Upload nginx ingress controller config
  provisioner "file" {
    content = templatefile(
      "${path.module}/templates/nginx_ingress.yaml.tpl",
      {
        version          = var.nginx_version
        values           = indent(4, trimspace(local.nginx_values))
        target_namespace = local.ingress_controller_namespace
    })
    destination = "/var/post_install/nginx_ingress.yaml"
  }

  # Upload haproxy ingress controller config
  provisioner "file" {
    content = templatefile(
      "${path.module}/templates/haproxy_ingress.yaml.tpl",
      {
        version          = var.haproxy_version
        values           = indent(4, trimspace(local.haproxy_values))
        target_namespace = local.ingress_controller_namespace
    })
    destination = "/var/post_install/haproxy_ingress.yaml"
  }

  # Upload Istio CRDs installer script
  provisioner "file" {
    content = templatefile(
      "${path.module}/templates/istio-install-crds.sh.tpl",
      {
        version = var.istio_version
      }
    )
    destination = "/var/post_install/istio-install-crds.sh"
  }
  
  # Make the script executable
  provisioner "remote-exec" {
    inline = [
      "chmod +x /var/post_install/istio-install-crds.sh"
    ]
  }

  # Upload istio direct installation script
  provisioner "file" {
    content = templatefile(
      "${path.module}/templates/istio-direct-install.sh.tpl",
      {
        version                          = var.istio_version
        values                           = trimspace(local.istio_values)
        target_namespace                 = local.ingress_controller_namespace
        load_balancer_name               = local.load_balancer_name
        load_balancer_location           = var.load_balancer_location
        load_balancer_type               = var.load_balancer_type
        load_balancer_disable_public_network = var.load_balancer_disable_public_network
        load_balancer_disable_ipv6       = var.load_balancer_disable_ipv6
        load_balancer_algorithm_type     = var.load_balancer_algorithm_type
        load_balancer_health_check_interval = var.load_balancer_health_check_interval
        load_balancer_health_check_timeout  = var.load_balancer_health_check_timeout
        load_balancer_health_check_retries  = var.load_balancer_health_check_retries
        uses_proxy_protocol              = !local.using_klipper_lb ? "true" : "false"
        lb_hostname                      = var.lb_hostname
        autoscaling                      = var.istio_autoscaling ? "true" : "false"
        replica_count                    = local.ingress_replica_count
        max_replica_count                = var.ingress_max_replica_count
      }
    )
    destination = "/var/post_install/istio-direct-install.sh"
  }
  
  # Make the script executable
  provisioner "remote-exec" {
    inline = [
      "chmod +x /var/post_install/istio-direct-install.sh"
    ]
  }
  
  # Also still provide a placeholder yaml for kustomization
  provisioner "file" {
    content = <<-EOT
---
# This is a placeholder file for Istio
# The actual installation now happens via the direct install script
apiVersion: v1
kind: ConfigMap
metadata:
  name: istio-installed-marker
  namespace: kube-system
data:
  info: "Istio is installed via script instead of HelmChart"
    EOT
    destination = "/var/post_install/istio.yaml"
  }

  # Upload istio debug script
  provisioner "file" {
    content = <<-EOT
#!/bin/bash
# Istio installation debug helper

function debug_istio_installation() {
  echo "=== Debugging Istio Installation ==="
  echo "Checking Helm resources..."
  kubectl get helmcharts,helmreleases -A
  
  echo "Checking Istio pods..."
  kubectl get pods -n kube-system -l app=istio -o wide
  
  echo "Checking Istio HelmChart resources..."
  kubectl get helmchart -n kube-system istio-ingress istiod -o yaml
  
  echo "Checking Helm install pods..."
  kubectl get pods -n kube-system -l owner=helm -o wide
  
  echo "Checking logs from failed Helm install pods..."
  for pod in $(kubectl get pods -n kube-system -l owner=helm --field-selector=status.phase!=Running -o name); do
    echo "=== Logs from $pod ==="
    kubectl logs -n kube-system $pod --all-containers
  done
  
  echo "Checking events..."
  kubectl get events -n kube-system --sort-by='.lastTimestamp' | grep -i 'istio\|helm'
  
  echo "=== End of Istio Debug Info ==="
}

function fix_istio_installation() {
  echo "=== Attempting to fix Istio Installation ==="
  
  # Delete any failed Helm install jobs
  echo "Cleaning up failed Helm install pods..."
  kubectl delete pods -n kube-system -l owner=helm --field-selector=status.phase!=Running
  
  # Clean up any potentially failed deployments
  echo "Cleaning up any failed Istio resources..."
  kubectl delete job -n kube-system helm-install-istiod 2>/dev/null || true
  kubectl delete job -n kube-system helm-install-gateway 2>/dev/null || true
  
  # Reinstall using the direct script
  echo "Reinstalling Istio using direct script..."
  /var/post_install/istio-direct-install.sh
  
  echo "=== Fix attempt completed ==="
}

# Export functions for use in the main script
export -f debug_istio_installation
export -f fix_istio_installation
EOT
    destination = "/var/post_install/istio_debug.sh"
  }

  # Upload the CCM patch config
  provisioner "file" {
    content = templatefile(
      "${path.module}/templates/ccm.yaml.tpl",
      {
        cluster_cidr_ipv4   = var.cluster_ipv4_cidr
        default_lb_location = var.load_balancer_location
        using_klipper_lb    = local.using_klipper_lb
    })
    destination = "/var/post_install/ccm.yaml"
  }

  # Upload the calico patch config, for the kustomization of the calico manifest
  # This method is a stub which could be replaced by a more practical helm implementation
  provisioner "file" {
    content = templatefile(
      "${path.module}/templates/calico.yaml.tpl",
      {
        values = trimspace(local.calico_values)
    })
    destination = "/var/post_install/calico.yaml"
  }

  # Upload the cilium install file
  provisioner "file" {
    content = templatefile(
      "${path.module}/templates/cilium.yaml.tpl",
      {
        values  = indent(4, trimspace(local.cilium_values))
        version = var.cilium_version
    })
    destination = "/var/post_install/cilium.yaml"
  }

  # Upload the system upgrade controller plans config
  provisioner "file" {
    content = templatefile(
      "${path.module}/templates/plans.yaml.tpl",
      {
        channel          = var.initial_k3s_channel
        version          = var.install_k3s_version
        disable_eviction = !var.system_upgrade_enable_eviction
        drain            = var.system_upgrade_use_drain
    })
    destination = "/var/post_install/plans.yaml"
  }

  # Upload the Longhorn config
  provisioner "file" {
    content = templatefile(
      "${path.module}/templates/longhorn.yaml.tpl",
      {
        longhorn_namespace  = var.longhorn_namespace
        longhorn_repository = var.longhorn_repository
        version             = var.longhorn_version
        bootstrap           = var.longhorn_helmchart_bootstrap
        values              = indent(4, trimspace(local.longhorn_values))
    })
    destination = "/var/post_install/longhorn.yaml"
  }

  # Upload the csi-driver config (ignored if csi is disabled)
  provisioner "file" {
    content = var.disable_hetzner_csi ? "" : templatefile(
      "${path.module}/templates/hcloud-csi.yaml.tpl",
      {
        version = coalesce(local.csi_version, "*")
        values  = indent(4, trimspace(local.hetzner_csi_values))
      }
    )
    destination = "/var/post_install/hcloud-csi.yaml"
  }

  # Upload the csi-driver-smb config
  provisioner "file" {
    content = templatefile(
      "${path.module}/templates/csi-driver-smb.yaml.tpl",
      {
        version   = var.csi_driver_smb_version
        bootstrap = var.csi_driver_smb_helmchart_bootstrap
        values    = indent(4, trimspace(local.csi_driver_smb_values))
    })
    destination = "/var/post_install/csi-driver-smb.yaml"
  }

  # Upload the cert-manager config
  provisioner "file" {
    content = templatefile(
      "${path.module}/templates/cert_manager.yaml.tpl",
      {
        version   = var.cert_manager_version
        bootstrap = var.cert_manager_helmchart_bootstrap
        values    = indent(4, trimspace(local.cert_manager_values))
    })
    destination = "/var/post_install/cert_manager.yaml"
  }

  # Upload the Rancher config
  provisioner "file" {
    content = templatefile(
      "${path.module}/templates/rancher.yaml.tpl",
      {
        rancher_install_channel = var.rancher_install_channel
        version                 = var.rancher_version
        bootstrap               = var.rancher_helmchart_bootstrap
        values                  = indent(4, trimspace(local.rancher_values))
    })
    destination = "/var/post_install/rancher.yaml"
  }

  provisioner "file" {
    content = templatefile(
      "${path.module}/templates/kured.yaml.tpl",
      {
        options = local.kured_options
      }
    )
    destination = "/var/post_install/kured.yaml"
  }

  # Deploy secrets, logging is automatically disabled due to sensitive variables
  provisioner "remote-exec" {
    inline = [
      "set -ex",
      "kubectl -n kube-system create secret generic hcloud --from-literal=token=${var.hcloud_token} --from-literal=network=${data.hcloud_network.k3s.name} --dry-run=client -o yaml | kubectl apply -f -",
      "kubectl -n kube-system create secret generic hcloud-csi --from-literal=token=${var.hcloud_token} --dry-run=client -o yaml | kubectl apply -f -",
    ]
  }

  # Deploy our post-installation kustomization
  provisioner "remote-exec" {
    inline = concat([
      "set -ex",

      # This ugly hack is here, because terraform serializes the
      # embedded yaml files with "- |2", when there is more than
      # one yamldocument in the embedded file. Kustomize does not understand
      # that syntax and tries to parse the blocks content as a file, resulting
      # in weird errors. so gnu sed with funny escaping is used to
      # replace lines like "- |3" by "- |" (yaml block syntax).
      # due to indendation this should not changes the embedded
      # manifests themselves
      "sed -i 's/^- |[0-9]\\+$/- |/g' /var/post_install/kustomization.yaml",

      # Wait for k3s to become ready (we check one more time) because in some edge cases,
      # the cluster had become unvailable for a few seconds, at this very instant.
      <<-EOT
      timeout 360 bash <<EOF
        until [[ "\$(kubectl get --raw='/readyz' 2> /dev/null)" == "ok" ]]; do
          echo "Waiting for the cluster to become ready..."
          sleep 2
        done
      EOF
      EOT
      ],
      [
        # Ready, set, go for the kustomization
        "kubectl apply -k /var/post_install",
        "echo 'Waiting for the system-upgrade-controller deployment to become available...'",
        "kubectl -n system-upgrade wait --for=condition=available --timeout=360s deployment/system-upgrade-controller",
        "sleep 7", # important as the system upgrade controller CRDs sometimes don't get ready right away, especially with Cilium.
        "kubectl -n system-upgrade apply -f /var/post_install/plans.yaml"
      ],
      local.has_external_load_balancer ? [] : [
        <<-EOT
        # Wait for appropriate load balancer IP based on ingress controller
        if [ "${var.ingress_controller}" = "istio" ]; then
          # Source the debug helper functions
          source /var/post_install/istio_debug.sh
          
          # Install Istio directly using our optimized script
          echo "Installing Istio directly using optimized script..."
          /var/post_install/istio-direct-install.sh
          
          # Wait for Istio ingress gateway service to get an IP
          echo "Waiting for Istio ingress gateway to get a load balancer IP..."
          timeout 600 bash <<'EOF'
            # Wait for the service to get an IP
            until [ -n "$(kubectl get -n ${local.ingress_controller_namespace} service/istio-ingressgateway --output=jsonpath='{.status.loadBalancer.ingress[0].${var.lb_hostname != "" ? "hostname" : "ip"}}' 2> /dev/null)" ]; do
              echo "Waiting for Istio ingress gateway load-balancer to get an IP... ($(date))"
              kubectl get service -n ${local.ingress_controller_namespace} istio-ingressgateway -o wide
              sleep 15
            done
            
            # Show final status
            echo "Istio ingress gateway load balancer has an IP:"
            kubectl get service -n ${local.ingress_controller_namespace} istio-ingressgateway -o wide
EOF
        elif [ "${var.ingress_controller}" != "none" ]; then
          # For traditional ingress controllers with improved observability
          timeout 900 bash <<'EOF'
            # Function to show detailed ingress controller status
            function show_ingress_status() {
              echo "--- Ingress Controller Status ($(date)) ---"
              echo "Service details:"
              kubectl get service -n ${local.ingress_controller_namespace} ${lookup(local.ingress_controller_service_names, var.ingress_controller)} -o wide 2>/dev/null || echo "Service not found"
              echo "Service status:"
              kubectl get service -n ${local.ingress_controller_namespace} ${lookup(local.ingress_controller_service_names, var.ingress_controller)} -o yaml | grep -A 15 status || echo "No status found"
              echo "Deployments:"
              kubectl get deployments -n ${local.ingress_controller_namespace} 2>/dev/null || echo "No deployments found"
              echo "Pods:"
              kubectl get pods -n ${local.ingress_controller_namespace} -o wide 2>/dev/null || echo "No pods found"
              echo "Events (last 5):"
              kubectl get events -n ${local.ingress_controller_namespace} --sort-by='.lastTimestamp' | tail -5 || echo "No events found"
              echo "-----------------------------------"
            }
            
            # Wait for the service to get an IP with status updates
            until [ -n "$(kubectl get -n ${local.ingress_controller_namespace} service/${lookup(local.ingress_controller_service_names, var.ingress_controller)} --output=jsonpath='{.status.loadBalancer.ingress[0].${var.lb_hostname != "" ? "hostname" : "ip"}}' 2> /dev/null)" ]; do
                echo "Waiting for load-balancer to get an IP... ($(date))"
                show_ingress_status
                sleep 15
            done
            
            # Show final status
            echo "Load balancer has an IP:"
            kubectl get service -n ${local.ingress_controller_namespace} ${lookup(local.ingress_controller_service_names, var.ingress_controller)} -o wide
EOF
        else
          echo "Skipping load balancer check when no ingress controller is enabled..."
        fi
        EOT
      ]
    )
  }

  depends_on = [
    hcloud_load_balancer.cluster,
    null_resource.control_planes,
    random_password.rancher_bootstrap,
    hcloud_volume.longhorn_volume
  ]
}
