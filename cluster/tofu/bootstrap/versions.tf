terraform {
  required_version = "~> 1.12"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.2"
    }
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
