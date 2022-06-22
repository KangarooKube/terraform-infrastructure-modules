output "aks_name" {
  description = "Name of the AKS Cluster deployed"
  value       = azurerm_kubernetes_cluster.aks.name
}

output "kube_config_raw" {
  description = "Admin Kubeconfig deployed"
  value       = azurerm_kubernetes_cluster.aks.kube_config_raw
  sensitive   = true
}

output "client_key" {
  value     = azurerm_kubernetes_cluster.aks.kube_config.0.client_key
  sensitive = true
}

output "client_certificate" {
  value     = azurerm_kubernetes_cluster.aks.kube_config.0.client_certificate
  sensitive = true
}

output "cluster_ca_certificate" {
  value     = azurerm_kubernetes_cluster.aks.kube_config.0.cluster_ca_certificate
  sensitive = true
}

output "cluster_username" {
  value     = azurerm_kubernetes_cluster.aks.kube_config.0.username
  sensitive = true
}

output "cluster_password" {
  value     = azurerm_kubernetes_cluster.aks.kube_config.0.password
  sensitive = true
}

output "host" {
  value = azurerm_kubernetes_cluster.aks.kube_config.0.host
}
