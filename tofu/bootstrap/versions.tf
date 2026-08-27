terraform {
  required_version = "~> 1.12"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.2"
    }
    # Maintained fork of gavinbunney/kubectl. Needed because it resolves resource kinds at
    # apply time, so it can create an Application whose CRD was installed earlier in the
    # same run -- which neither helm's extraObjects nor kubernetes_manifest can do.
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.4"
    }
  }
}

provider "helm" {
  kubernetes = {
    config_path = pathexpand(var.kubeconfig_path)
  }
}

provider "kubectl" {
  config_path      = pathexpand(var.kubeconfig_path)
  load_config_file = true
}
