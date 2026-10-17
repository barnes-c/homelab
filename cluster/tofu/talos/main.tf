locals {
  control_planes = { for k, v in var.nodes : k => v if v.role == "controlplane" }
  workers        = { for k, v in var.nodes : k => v if v.role == "worker" }

  control_plane_ips = [for node in local.control_planes : node.ip]

  common_patch = {
    machine = {
      time = { servers = var.ntp_servers }
      sysctls = {
        "kernel.printk" = "8 4 1 7"
      }
      registries = {
        mirrors = { for host, endpoints in var.registry_mirrors : host => { endpoints = endpoints } }
      }
      features = {
        rbac                 = true
        apidCheckExtKeyUsage = true
        diskQuotaSupport     = true
      }
    }
  }

  kubelet_patch = {
    apiVersion = "v1alpha1"
    kind       = "KubeletConfig"
    extraArgs = {
      rotate-server-certificates = "true"
    }
  }

  resolver_patch = {
    apiVersion = "v1alpha1"
    kind       = "ResolverConfig"
    hostDNS = {
      enabled              = true
      resolveMemberNames   = true
      forwardKubeDNSToHost = false
    }
  }

  disable_flannel_patch = {
    apiVersion = "v1alpha1"
    kind       = "KubeFlannelCNIConfig"
    "$patch"   = "delete"
  }

  disable_kubeproxy_patch = {
    apiVersion = "v1alpha1"
    kind       = "KubeProxyConfig"
    enabled    = false
  }

  pod_security_patch = {
    apiVersion = "v1alpha1"
    kind       = "KubeAdmissionControlConfig"
    name       = "PodSecurity"
    configuration = {
      apiVersion = "pod-security.admission.config.k8s.io/v1alpha1"
      kind       = "PodSecurityConfiguration"
      defaults = {
        enforce           = "restricted"
        "enforce-version" = "latest"
        audit             = "restricted"
        "audit-version"   = "latest"
        warn              = "restricted"
        "warn-version"    = "latest"
      }
    }
  }

  install_patch = {
    for k, v in var.nodes : k => {
      apiVersion = "v1alpha1"
      kind       = "UnattendedInstallConfig"
      installer  = { image = v.install_image }
      provisioning = {
        diskSelector = { match = "disk.dev_path == \"${v.install_disk}\"" }
        wipe         = false
      }
    }
  }

  # Control planes only. allowSchedulingOnControlPlanes is deprecated (k8s/node.go:188);
  # scheduling is now governed by the taints in KubeNodeConfig. A strategic-merge patch
  # cannot remove a map key and JSON6902 is rejected on multi-document configs, so the
  # document is deleted and re-added without the control-plane NoSchedule taint. The
  # control-plane labels are restated deliberately, since the delete drops them too.
  schedulable_patches = {
    for k, v in local.control_planes : k => [
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "KubeNodeConfig"
        "$patch"   = "delete"
      }),
      yamlencode(merge({
        apiVersion = "v1alpha1"
        kind       = "KubeNodeConfig"
        nodeIP     = {}
        labels = merge({
          "node-role.kubernetes.io/control-plane"                   = ""
          "node.kubernetes.io/exclude-from-external-load-balancers" = ""
        }, v.node_labels)
      }, length(v.node_annotations) > 0 ? { annotations = v.node_annotations } : {})),
    ]
  }

  # Workers keep the generated KubeNodeConfig (it carries no control-plane taint), so
  # labels and annotations merge in rather than needing the delete/re-add dance.
  worker_label_patch = {
    for k, v in local.workers : k => yamlencode(merge(
      { apiVersion = "v1alpha1", kind = "KubeNodeConfig", labels = v.node_labels },
      length(v.node_annotations) > 0 ? { annotations = v.node_annotations } : {},
    )) if length(v.node_labels) > 0 || length(v.node_annotations) > 0
  }

  # Hostname moved out of v1alpha1 in Talos v1.14. Config generation now emits a
  # HostnameConfig document with `auto: stable`, and setting machine.network.hostname
  # alongside it fails validation with "static hostname is already set in v1alpha1 config"
  # (network/hostname.go:153). `auto` and `hostname` are also mutually exclusive unless
  # auto is "off", and since a patch merges into the generated document, auto has to be
  # overridden explicitly rather than just omitted. Quoted so YAML cannot read it as false.
  hostname_patch = {
    for k, v in var.nodes : k => {
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      auto       = "off"
      hostname   = k
    }
  }

  # EPHEMERAL carries ETCD/CRI/KUBELET/LOG as directories underneath it. Whether those are
  # directories or dedicated partitions is fixed at cluster creation and cannot be changed
  # on a provisioned node (machinery/config/types/block/volume_config.go). Directories are
  # the right call on mirrored SSDs for a cluster this size.
  ephemeral_patch = {
    for k, v in var.nodes : k => {
      apiVersion = "v1alpha1"
      kind       = "VolumeConfig"
      name       = "EPHEMERAL"
      # `grow` must stay a bool: ProvisioningGrow is *bool (volume_config.go:145) and Talos
      # rejects the string "false". Keep it in a map that also holds diskSelector -- mixing
      # an object with a bool forces an object type, which preserves per-key types. Putting
      # it alongside only strings (e.g. maxSize) makes HCL unify everything to map(string).
      provisioning = merge(
        {
          diskSelector = { match = v.ephemeral_selector }
          grow         = v.ephemeral_max_size == null
        },
        v.ephemeral_max_size != null ? { maxSize = v.ephemeral_max_size } : {},
      )
    } if v.ephemeral_selector != null
  }

  # Longhorn backing store, mounted at /var/mnt/longhorn.
  longhorn_patch = {
    for k, v in var.nodes : k => {
      apiVersion = "v1alpha1"
      kind       = "UserVolumeConfig"
      name       = "longhorn"
      provisioning = merge(
        { diskSelector = { match = v.longhorn_selector }, grow = true },
        v.longhorn_min_size != null ? { minSize = v.longhorn_min_size } : {},
      )
    } if v.longhorn_selector != null
  }

  # Ordering matters: the VIP has to exist before the second control plane joins.
  vip_patch = {
    machine = {
      network = {
        interfaces = [{
          interface = "end0"
          dhcp      = true
          vip       = { ip = var.cluster_vip }
        }]
      }
    }
  }

  # Workaround for TX checksum offload stalls on the RP1 MAC. May be redundant since the
  # macb fixes landed in v1.14.0-rc.2 -- see barnes-c/homelab-issues#20.
  ethernet_patch = {
    apiVersion = "v1alpha1"
    kind       = "EthernetConfig"
    name       = "end0"
    features = {
      "tx-tcp-segmentation" = false
      "tx-scatter-gather"   = false
    }
  }

  # The Pi cores idle at 1.5GHz under the default governor, which shows up as etcd
  # fsync latency on a cluster this small.
  governor_patch = {
    machine = {
      udev = {
        rules = ["SUBSYSTEM==\"cpu\", ACTION==\"add\", ATTR{cpufreq/scaling_governor}=\"performance\""]
      }
    }
  }

  patches = {
    for k, v in var.nodes : k => compact(concat(
      [
        yamlencode(local.common_patch),
        yamlencode(local.install_patch[k]),
        yamlencode(local.hostname_patch[k]),
        yamlencode(local.kubelet_patch),
        yamlencode(local.resolver_patch),
        yamlencode(local.ethernet_patch),
        yamlencode(local.governor_patch),
      ],
      # KubeProxyConfig and KubeFlannelCNIConfig are rejected on workers -- Talos allows
      # them only on control planes ("the following document kinds are only allowed on
      # control plane machines"). That is correct: they decide which manifests the control
      # plane renders cluster-wide, so a worker has no business carrying them.
      v.role == "controlplane" ? concat(
        [
          yamlencode(local.disable_flannel_patch),
          yamlencode(local.disable_kubeproxy_patch),
          yamlencode(local.pod_security_patch),
          yamlencode(local.vip_patch),
          yamlencode({
            cluster = {
              etcd = { advertisedSubnets = ["192.168.0.0/16"] }
            }
          }),
        ],
        local.schedulable_patches[k],
      ) : [],
      lookup(local.worker_label_patch, k, null) != null ? [local.worker_label_patch[k]] : [],
      lookup(local.ephemeral_patch, k, null) != null ? [yamlencode(local.ephemeral_patch[k])] : [],
      lookup(local.longhorn_patch, k, null) != null ? [yamlencode(local.longhorn_patch[k])] : [],
    ))
  }
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

# Without a CNI the API server never reports ready, so this is the real gate on
# tofu/bootstrap being able to run.
# Deliberately no talos_cluster_health data source here.
#
# It was declared as a gate on the cluster being up, but nothing consumed its output, so
# it only ever blocked. Worse, once every input is known (which it is as soon as the
# secrets exist in state) OpenTofu reads it during PLAN -- so adding a node that has not
# been provisioned yet makes `tofu plan` hang waiting for that node to report healthy,
# before you have had a chance to apply the config that would make it healthy.
#
# Check health explicitly instead:
#   talosctl -n <control-plane-ip> health
