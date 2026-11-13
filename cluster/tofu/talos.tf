locals {
  bootstrap_ip      = var.nodes["pi5-cp-01"].ip
  control_plane_ips = [for node in local.control_planes : node.ip]
  control_planes    = { for k, v in var.nodes : k => v if v.role == "controlplane" }
  patches = {
    for k, v in var.nodes : k => concat(
      [
        templatefile("${local.patches_dir}/time-sync.yaml.tftpl", { ntp_servers = var.ntp_servers }),
        templatefile("${local.patches_dir}/install.yaml.tftpl", { image = v.install_image, disk = v.install_disk }),
        templatefile("${local.patches_dir}/hostname.yaml.tftpl", { hostname = k }),
        file("${local.patches_dir}/kubelet.yaml"),
        file("${local.patches_dir}/resolver.yaml"),
        file("${local.patches_dir}/firewall.yaml"),
        file("${local.patches_dir}/watchdog.yaml"),
        file("${local.patches_dir}/kmsg-log.yaml"),
      ],
      v.role == "controlplane" ? [
        file("${local.patches_dir}/controlplane/disable-flannel.yaml"),
        file("${local.patches_dir}/controlplane/disable-kubeproxy.yaml"),
        file("${local.patches_dir}/controlplane/pod-security.yaml"),
        file("${local.patches_dir}/controlplane/controller-manager.yaml"),
        templatefile("${local.patches_dir}/controlplane/vip.yaml.tftpl", { vip = var.cluster_vip }),
        file("${local.patches_dir}/controlplane/etcd.yaml"),
        file("${local.patches_dir}/controlplane/node-delete.yaml"),
        templatefile("${local.patches_dir}/controlplane/node.yaml.tftpl", {
          labels      = v.node_labels
          annotations = v.node_annotations
        }),
      ] : [],
      v.role == "worker" && (length(v.node_labels) > 0 || length(v.node_annotations) > 0) ? [
        templatefile("${local.patches_dir}/worker/node-labels.yaml.tftpl", {
          labels      = v.node_labels
          annotations = v.node_annotations
        }),
      ] : [],
      v.ephemeral_selector != null ? [
        templatefile("${local.patches_dir}/ephemeral.yaml.tftpl", {
          selector = v.ephemeral_selector
          max_size = v.ephemeral_max_size
        }),
      ] : [],
      v.longhorn_selector != null ? [
        templatefile("${local.patches_dir}/longhorn.yaml.tftpl", {
          selector = v.longhorn_selector
          min_size = v.longhorn_min_size
        }),
      ] : [],
      length(v.sysfs) > 0 ? [templatefile("${local.patches_dir}/sysfs.yaml.tftpl", { params = v.sysfs })] : [],
      v.rp1_ethernet ? [file("${local.patches_dir}/rp1-ethernet.yaml")] : [],
    )
  }
  patches_dir = "${path.module}/patches"
}

resource "talos_machine_secrets" "cluster" {
  talos_version = var.talos_version

  # Changing talos_version regenerates every CA and the cluster ID, which locks all nodes out.
  # The secrets are generated once; only the machine configs follow var.talos_version.
  lifecycle {
    ignore_changes = [talos_version]
  }
}

data "talos_client_configuration" "cluster" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.cluster.client_configuration
  endpoints            = local.control_plane_ips
}

ephemeral "talos_machine_configuration" "node" {
  for_each = var.nodes

  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${var.cluster_vip}:6443"
  machine_type     = each.value.role
  machine_secrets  = talos_machine_secrets.cluster.machine_secrets
  config_patches   = local.patches[each.key]

  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version
}

# OS upgrades stay on talosctl. `image` only exists so Create does not attempt an upgrade
# when it is omitted; it must match the running version, and the node reports the Pi 5 tag
# without the -pwmfan suffix. See barnes-c/homelab-issues#81.
resource "talos_machine" "node" {
  for_each = var.nodes

  client_configuration     = talos_machine_secrets.cluster.client_configuration
  machine_configuration_wo = ephemeral.talos_machine_configuration.node[each.key].machine_configuration
  node                     = each.value.ip
  image                    = trimsuffix(each.value.install_image, "-pwmfan")
  drain_on_upgrade         = false

  ignore_kubernetes_upgrade_drift = true

  on_destroy = {
    graceful = false
    reboot   = true
    reset    = true
  }

  lifecycle {
    ignore_changes = [image]
  }
}

resource "talos_cluster" "cluster" {
  client_configuration_wo = talos_machine_secrets.cluster.client_configuration
  node                    = local.bootstrap_ip
  control_plane_nodes     = local.control_plane_ips
  kubernetes_version      = var.kubernetes_version

  depends_on = [talos_machine.node]
}

resource "talos_cluster_kubeconfig" "cluster" {
  client_configuration = talos_machine_secrets.cluster.client_configuration
  node                 = local.bootstrap_ip
  endpoint             = local.bootstrap_ip

  depends_on = [talos_cluster.cluster]
}

ephemeral "talos_cluster_kubeconfig" "cluster" {
  cluster_name    = var.cluster_name
  endpoint        = "https://${var.cluster_vip}:6443"
  machine_secrets = talos_machine_secrets.cluster.machine_secrets
}

# A fresh cluster takes two applies: -target=talos_cluster.cluster first, since the providers'
# kubeconfig is built from machine secrets that don't exist until then; restore the sealed-secrets
# keys before the second. talos_cluster waits for etcd/apid/kubelet, not the API server.
# See barnes-c/homelab-issues#80.
