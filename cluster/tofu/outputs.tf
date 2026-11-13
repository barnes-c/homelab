output "cluster_endpoint" {
  description = "Kubernetes API endpoint"
  value       = "https://${var.cluster_vip}:6443"
}

output "disk_images" {
  description = "Bootable SD image per Image Factory schematic, for the initial flash"
  value       = { for k, v in data.talos_image_factory_urls.schematic : k => v.urls.disk_image }
}

output "kubeconfig" {
  description = "kubeconfig for the cluster"
  value       = talos_cluster_kubeconfig.cluster.kubeconfig_raw
  sensitive   = true
}

output "node_ips" {
  description = "Node hostname to IP"
  value       = { for k, v in var.nodes : k => v.ip }
}

output "talosconfig" {
  description = "talosconfig for talosctl"
  value       = data.talos_client_configuration.cluster.talos_config
  sensitive   = true
}
