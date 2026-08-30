variable "cluster_name" {
  description = "Name of the Talos cluster"
  type        = string
  default     = "barnes-lab"
}

variable "cluster_vip" {
  description = "Virtual IP for the cluster API endpoint, shared by the control plane"
  type        = string
  default     = "192.168.1.10"
}

variable "talos_version" {
  description = <<-EOT
    Talos version the machine config schema is generated for. v1.14.0 is not released
    yet -- rc.2 is the newest tag, and the Pi 5 runs one commit past it.
  EOT
  type        = string
  default     = "v1.14.0-rc.2"
}

variable "kubernetes_version" {
  description = <<-EOT
    Kubernetes version. Talos v1.14.0-rc.2 defaults to 1.37.0-rc.1 only because it was cut
    before 1.37.0 went GA; the value just selects image tags, and 1.37 is the newest of the
    6 supported versions (constants.go:381-384).
  EOT
  type        = string
  default     = "1.37.0"
}

variable "ntp_servers" {
  description = "NTP servers. Anycast Cloudflare + Google, v4 and v6."
  type        = list(string)
  default     = ["162.159.200.1", "216.239.35.0", "2606:4700:f1::1", "2001:4860:4806::"]
}

variable "nodes" {
  description = <<-EOT
    Cluster nodes, keyed by hostname.

    install_image: Pi 5 points at a locally built installer carrying the NTP cert-regen
    fix (cb393a0d7), which is not upstream. Workers use stock Image Factory images,
    written here by `make schematics`.

    ephemeral_selector / longhorn_selector: CEL over Talos DiskSpec. Pin by wwid when
    disks are identical -- `transport` and device names are not stable across reboots.
    Run `talosctl get disks` on a node in maintenance mode to read the real values.
  EOT

  type = map(object({
    ip            = string
    role          = string # "controlplane" | "worker"
    install_disk  = string
    install_image = string

    # Where EPHEMERAL (and therefore ETCD/CRI/KUBELET/LOG) lands. Null keeps it on the
    # install disk, which is correct only where that disk is not an SD card.
    ephemeral_selector = optional(string)
    ephemeral_max_size = optional(string)

    # Backing store for Longhorn, mounted at /var/mnt/longhorn.
    longhorn_selector = optional(string)
    longhorn_min_size = optional(string)

    # Extra Kubernetes node labels, applied via KubeNodeConfig.
    node_labels = optional(map(string), {})
  }))

  default = {
    # 2x Samsung 870 2TB on a Radxa Penta SATA HAT, mirrored as md127.
    # EPHEMERAL on the mirror keeps etcd off the SD card; the SD keeps only META + STATE.
    "rpi5b-cp-01" = {
      ip            = "192.168.1.11"
      role          = "controlplane"
      install_disk  = "/dev/mmcblk0"
      install_image = "192.168.1.18:5005/talos/installer:v1.14.0-rc.2-1-gcb393a0d7"

      # Verified on hardware: md127 is RAID1 over sda+sdb (Samsung 870 2TB), [UU], and
      # already backs EPHEMERAL at /dev/md127p2. The array has no wwid of its own, so
      # match on dev_path. Talos DISCOVERS mdraid arrays but cannot CREATE them -- there
      # is no array-creation controller -- so this array must survive any re-provision.
      ephemeral_selector = "disk.dev_path == '/dev/md127'"
      ephemeral_max_size = "300GiB"
      longhorn_selector  = "disk.dev_path == '/dev/md127'"
      longhorn_min_size  = "500GiB"

      # Paired with createDefaultDiskLabeledNodes in apps/longhorn.yaml: only nodes
      # carrying this label get a Longhorn disk. Without it Longhorn would create one on
      # every node at defaultDataPath, including workers whose only storage is an SD card.
      node_labels = {
        "node.longhorn.io/create-default-disk" = "true"
      }
    }

    # Compute-only worker: its USB SSD does not enumerate, so it has only the SD card and
    # is deliberately unlabelled for Longhorn, which would otherwise wear the card out.
    # See #52.
    "rpi4b-wk-01" = {
      ip            = "192.168.1.12"
      role          = "worker"
      install_disk  = "/dev/mmcblk0"
      install_image = "factory.talos.dev/metal-installer/b3a0359a76da43ab16121ec916e421be6af9ed098dc5740d88683cf93eef2133:v1.14.0-rc.2"
    }

    # "cm5-wk-01" = {
    #   ip            = "192.168.1.13"
    #   role          = "worker"
    #   install_disk  = "/dev/nvme0n1"
    #   install_image = "factory.talos.dev/metal-installer/CHANGEME:v1.14.0-rc.2"
    #   longhorn_selector = "disk.transport == 'nvme'"
    #   longhorn_min_size = "100GiB"
    # }
    # "cm5-wk-02" = {
    #   ip            = "192.168.1.14"
    #   role          = "worker"
    #   install_disk  = "/dev/nvme0n1"
    #   install_image = "factory.talos.dev/metal-installer/CHANGEME:v1.14.0-rc.2"
    #   longhorn_selector = "disk.transport == 'nvme'"
    #   longhorn_min_size = "100GiB"
    # }
  }

  validation {
    condition     = length([for n in var.nodes : n if n.role == "controlplane"]) > 0
    error_message = "At least one node must have role = \"controlplane\"."
  }
}

variable "registry_mirrors" {
  description = <<-EOT
    Extra registry mirrors. The local build registry is plain HTTP, and insecureSkipVerify
    only covers bad TLS rather than its absence, so the scheme must be explicit.
    Note the node cannot upgrade while this registry is offline.
  EOT
  type        = map(list(string))
  default = {
    "192.168.1.18:5005" = ["http://192.168.1.18:5005"]
  }
}
