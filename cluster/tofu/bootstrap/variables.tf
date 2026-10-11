variable "kubeconfig_path" {
  description = "Path to the kubeconfig written by `tofu -chdir=../talos output`"
  type        = string
  default     = "~/.kube/config"
}

variable "control_plane_count" {
  description = "Number of control-plane nodes. Drives the Cilium operator replica count."
  type        = number
  default     = 1
}

variable "cilium_extra_values" {
  description = "Merged over the Talos-specific Cilium defaults"
  type        = any
  default     = {}
}

variable "argocd_extra_values" {
  description = "Merged over the ArgoCD defaults"
  type        = any
  default     = {}
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

variable "apps_path" {
  description = "Path within the repo containing Application manifests"
  type        = string
  default     = "apps"
}
