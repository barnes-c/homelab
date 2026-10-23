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
    talos = {
      source  = "siderolabs/talos"
      version = "0.12.0"
    }
  }
}
