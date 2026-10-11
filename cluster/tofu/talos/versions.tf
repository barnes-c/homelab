terraform {
  required_version = "~> 1.12"

  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = "0.12.0"
    }
  }
}
