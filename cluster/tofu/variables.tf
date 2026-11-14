variable "apps_path" {
  description = "Path within the repo containing Application manifests"
  type        = string
  default     = "apps"
}

variable "apps_repo" {
  description = "Git repository holding the ArgoCD Application manifests"
  type        = string
  default     = "https://github.com/barnes-c/homelab"
}

variable "apps_revision" {
  description = "Git revision to track"
  type        = string
  default     = "master"
}

variable "argocd_extra_values" {
  description = "Merged over the ArgoCD defaults"
  type        = any
  default     = {}
}

variable "cilium_extra_values" {
  description = "Merged over the Talos-specific Cilium defaults"
  type        = any
  default     = {}
}

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

variable "kubernetes_version" {
  description = "Kept on 1.37: Talos v1.15.0-beta.0 defaults to the 1.38.0-beta.0 pre-release"
  type        = string
  default     = "1.37.2"
}

variable "nodes" {
  description = "Cluster nodes, keyed by hostname"
  type = map(object({
    ip           = string
    role         = string # "controlplane" | "worker"
    install_disk = optional(string, "/dev/mmcblk0")

    # Exactly one: a schematic in schematics/ (Image Factory), or a full installer image.
    schematic     = optional(string)
    install_image = optional(string)

    # CEL over Talos DiskSpec for the disk holding EPHEMERAL (etcd, CRI, logs) and Longhorn.
    # Null keeps EPHEMERAL on the install disk. Device names and transport aren't stable
    # across reboots; read real values with `talosctl get disks` in maintenance mode.
    data_disk          = optional(string)
    ephemeral_max_size = optional(string)
    longhorn_min_size  = optional(string)
    longhorn_tag       = optional(string)

    # Keys are /sys paths with dots for slashes.
    sysfs = optional(map(string), {})

    # Pi 5 / CM5 (RP1 MAC) only: turns off TX offloads on end0. See barnes-c/homelab-issues#20.
    rp1_ethernet = optional(bool, false)
  }))

  default = {
    # 2x Samsung 870 2TB on a Radxa Penta SATA HAT as RAID1 md127. It has no wwid, so it is
    # matched by dev_path. Talos can discover mdraid but not create it: the array must survive
    # any re-provision.
    "pi5-cp-01" = {
      ip                 = "192.168.1.11"
      role               = "controlplane"
      install_image      = "ghcr.io/barnes-c/talos/installer:v1.15.0-beta.0-pwmfan"
      data_disk          = "disk.dev_path == '/dev/md127'"
      ephemeral_max_size = "300GiB"
      longhorn_min_size  = "500GiB"
      longhorn_tag       = "persistent"
      rp1_ethernet       = true

      # Fan PWM enabled at 0% rather than disabled: on disable the rp1-pwm driver drops the
      # inverted polarity and the fan runs flat out. hwmon2 is fixed by driver probe order.
      # See barnes-c/homelab-issues#8.
      sysfs = {
        "devices.platform.cooling_fan.hwmon.hwmon2.pwm1_enable" = "2"
      }
    }

    # Samsung T7 500GB on USB, matched by model: the USB bridge reports a generic wwid.
    "pi4-wk-01" = {
      ip                 = "192.168.1.12"
      role               = "worker"
      schematic          = "pi4"
      data_disk          = "disk.model == 'PSSD T7'"
      ephemeral_max_size = "50GiB"
      longhorn_min_size  = "400GiB"
      longhorn_tag       = "scratch"
    }

    # CM5s: Talos on the eMMC, data on a Transcend 256GB NVMe. Same model on both, so pinned by wwid.
    "cm5-cp-01" = {
      ip                 = "192.168.1.13"
      role               = "controlplane"
      schematic          = "cm5"
      data_disk          = "disk.wwid == 'eui.00000000000000007c35485256bde646'"
      ephemeral_max_size = "50GiB"
      longhorn_min_size  = "100GiB"
      longhorn_tag       = "scratch"
      rp1_ethernet       = true
    }

    "cm5-cp-02" = {
      ip                 = "192.168.1.14"
      role               = "controlplane"
      schematic          = "cm5"
      data_disk          = "disk.wwid == 'eui.00000000000000007c35485256bde5a1'"
      ephemeral_max_size = "50GiB"
      longhorn_min_size  = "100GiB"
      longhorn_tag       = "scratch"
      rp1_ethernet       = true
    }
  }

  validation {
    condition     = length([for n in var.nodes : n if n.role == "controlplane"]) > 0
    error_message = "At least one node must have role = \"controlplane\"."
  }

  validation {
    condition     = alltrue([for n in var.nodes : (n.schematic == null) != (n.install_image == null)])
    error_message = "Each node needs exactly one of schematic or install_image."
  }
}

variable "ntp_servers" {
  description = "NTP servers. Anycast Cloudflare + Google, v4 and v6."
  type        = list(string)
  default     = ["162.159.200.1", "216.239.35.0", "2606:4700:f1::1", "2001:4860:4806::"]
}

variable "state_passphrase" {
  description = "Encrypts state and plan files; from TF_VAR_state_passphrase, never in git"
  type        = string
  sensitive   = true
}

variable "talos_image_version" {
  description = "Talos release the Image Factory installers are built for"
  type        = string
  default     = "v1.15.0-beta.0"
}

variable "talos_version" {
  description = "Machine config contract version; not newer than the oldest node."
  type        = string
  default     = "v1.15.0-beta.0"
}
