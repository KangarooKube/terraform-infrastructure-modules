output "log_ws_resource_name" {
  description = "Name of the Log Analytics Workspace"
  value       = azurerm_log_analytics_workspace.log_ws.name
}

output "log_ws_resource_id" {
  description = "ID of the Log Analytics Workspace"
  value       = azurerm_log_analytics_workspace.log_ws.id
}

output "log_ws_primary_shared_key" {
  description = "Primary Shared Key of the Log Analytics Workspace"
  value       = azurerm_log_analytics_workspace.log_ws.primary_shared_key
}

output "log_ws_secondary_shared_key" {
  description = "Secondary Shared Key of the Log Analytics Workspace"
  value       = azurerm_log_analytics_workspace.log_ws.secondary_shared_key
}