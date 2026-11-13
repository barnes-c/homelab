locals {
  bootstrap_ip      = var.nodes["pi5-cp-01"].ip
  control_plane_ips = [for node in local.control_planes : node.ip]
  control_planes    = { for k, v in var.nodes : k => v if v.role == "controlplane" }
  # Paired with createDefaultDiskLabeledNodes in manifests/infrastructure/longhorn/values.yaml: only
  # labelled nodes get a Longhorn disk, taken with its tags from the annotation. Longhorn reads it
  # only while the node has no disk yet.
  longhorn_node_config = {
    for k, v in var.nodes : k => {
      labels = { for t in [v.longhorn_tag] : "node.longhorn.io/create-default-disk" => "config" if t != null }
      annotations = {
        for t in [v.longhorn_tag] : "node.longhorn.io/default-disks-config" =>
        format("[{\"path\":\"/var/mnt/longhorn\",\"allowScheduling\":true,\"tags\":[%q]}]", t) if t != null
      }
    }
  }
  patches = {
    for k, v in var.nodes : k => concat(
      [
        templatefile("${local.patches_dir}/time-sync.yaml.tftpl", { ntp_servers = var.ntp_servers }),
        templatefile("${local.patches_dir}/install.yaml.tftpl", { image = local.install_images[k], disk = v.install_disk }),
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
        templatefile("${local.patches_dir}/controlplane/node.yaml.tftpl", local.longhorn_node_config[k]),
      ] : [],
      v.role == "worker" && v.longhorn_tag != null ? [
        templatefile("${local.patches_dir}/worker/node-labels.yaml.tftpl", local.longhorn_node_config[k]),
      ] : [],
      v.data_disk != null ? [
        templatefile("${local.patches_dir}/ephemeral.yaml.tftpl", {
          selector = v.data_disk
          max_size = v.ephemeral_max_size
        }),
        templatefile("${local.patches_dir}/longhorn.yaml.tftpl", {
          selector = v.data_disk
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

  # Changing talos_version regenerates every CA and cluster ID = locked out.
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

# OS upgrades stay on talosctl (ignore_changes = [image]). Two things block managing them here:
# - The Pi 5 installer tag (-pwmfan) never equals the version the node reports, so every apply
#   would reinstall and reboot it. Gone once the fan kernel is upstream (barnes-c/homelab-issues#8).
# - for_each upgrades all nodes in parallel; three control planes rebooting at once lose etcd
#   quorum. Needs -parallelism=1 or per-node resources chained with depends_on.
# `image` is set only so Create doesn't attempt an upgrade when it's omitted; it must match the
# running version, hence the trimsuffix. See barnes-c/homelab-issues#81.
resource "talos_machine" "node" {
  for_each = var.nodes

  client_configuration     = talos_machine_secrets.cluster.client_configuration
  machine_configuration_wo = ephemeral.talos_machine_configuration.node[each.key].machine_configuration
  node                     = each.value.ip
  image                    = trimsuffix(local.install_images[each.key], "-pwmfan")
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
