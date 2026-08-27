output "kubeconfig" {
  description = "kubeconfig for the cluster"
  value       = talos_cluster_kubeconfig.cluster.kubeconfig_raw
  sensitive   = true
}

output "talosconfig" {
  description = "talosconfig for talosctl"
  value       = data.talos_client_configuration.cluster.talos_config
  sensitive   = true
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint"
  value       = "https://${var.cluster_vip}:6443"
}

output "node_ips" {
  description = "Node hostname to IP"
  value       = { for k, v in var.nodes : k => v.ip }
}
