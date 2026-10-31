locals {
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
        file("${local.patches_dir}/governor.yaml"),
        file("${local.patches_dir}/firewall.yaml"),
        file("${local.patches_dir}/watchdog.yaml"),
      ],
      length(var.registry_mirrors) > 0 ? [
        templatefile("${local.patches_dir}/registry-mirrors.yaml.tftpl", { registry_mirrors = var.registry_mirrors }),
      ] : [],
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

data "talos_machine_configuration" "node" {
  for_each = var.nodes

  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${var.cluster_vip}:6443"
  machine_type     = each.value.role
  machine_secrets  = talos_machine_secrets.cluster.machine_secrets

  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version
}

resource "talos_machine_configuration_apply" "node" {
  for_each = var.nodes

  client_configuration        = talos_machine_secrets.cluster.client_configuration
  machine_configuration_input = data.talos_machine_configuration.node[each.key].machine_configuration
  node                        = each.value.ip
  endpoint                    = each.value.ip
  apply_mode                  = "auto"

  config_patches = local.patches[each.key]

  on_destroy = {
    graceful = false
    reboot   = true
    reset    = true
  }
}

resource "talos_machine_bootstrap" "cluster" {
  client_configuration = talos_machine_secrets.cluster.client_configuration
  node                 = local.control_plane_ips[0]
  endpoint             = local.control_plane_ips[0]

  depends_on = [talos_machine_configuration_apply.node]
}

resource "talos_cluster_kubeconfig" "cluster" {
  client_configuration = talos_machine_secrets.cluster.client_configuration
  node                 = local.control_plane_ips[0]
  endpoint             = local.control_plane_ips[0]

  depends_on = [talos_machine_bootstrap.cluster]
}

# A fresh cluster is applied in two steps on purpose (README Step 3): -target this first, then
# restore the sealed-secrets keys before anything syncs. No talos_cluster_health gate: it is
# read during plan and hangs on unprovisioned nodes. See barnes-c/homelab-issues#48.
