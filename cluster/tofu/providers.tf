locals {
  k8s = talos_cluster_kubeconfig.cluster.kubernetes_client_configuration
  k8s_auth = {
    host                   = local.k8s.host
    cluster_ca_certificate = base64decode(local.k8s.ca_certificate)
    client_certificate     = base64decode(local.k8s.client_certificate)
    client_key             = base64decode(local.k8s.client_key)
  }
}

provider "helm" {
  kubernetes = local.k8s_auth
}

provider "kubectl" {
  host                   = local.k8s_auth.host
  cluster_ca_certificate = local.k8s_auth.cluster_ca_certificate
  client_certificate     = local.k8s_auth.client_certificate
  client_key             = local.k8s_auth.client_key
  load_config_file       = false
}
