terraform {
  required_version = "~> 1.12"

  backend "http" {
    lock_method    = "POST"
    unlock_method  = "DELETE"
    retry_wait_min = 5
  }
  encryption {
    key_provider "pbkdf2" "state" {
      passphrase = var.state_passphrase
    }
    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }
    state {
      method   = method.aes_gcm.state
      enforced = true
    }
    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.2"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 3.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "0.12.0"
    }
  }
}
