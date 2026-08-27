terraform {
  required_version = "~> 1.12"

  required_providers {
    talos = {
      source = "siderolabs/talos"
      # Must match the cluster's Talos minor. v1.14 decomposed v1alpha1 into standalone
      # documents (UnattendedInstallConfig, HostnameConfig, KubeletConfig, ...); provider
      # 0.11.0 bundles machinery v1.13.0 and rejects them with "not registered".
      # 0.12.0-beta.0 bundles v1.14.0-rc.2. Pinned exactly because prerelease versions are
      # not selected by range constraints.
      version = "0.12.0-beta.0"
    }
  }
}
