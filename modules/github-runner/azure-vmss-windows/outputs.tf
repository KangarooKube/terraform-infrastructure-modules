output "resource_group_name" {
  description = "Resource group containing the Windows runner VMSS"
  value       = local.resource_group_name
}

output "location" {
  description = "Azure region"
  value       = local.location
}

output "vnet_name" {
  description = "Virtual network name"
  value       = local.vnet_name
}

output "subnet_id" {
  description = "ID of the snet-runners-windows subnet"
  value       = azurerm_subnet.runners.id
}

output "nsg_id" {
  description = "ID of the NSG attached to the Windows runners subnet"
  value       = azurerm_network_security_group.runners.id
}

output "vmss_name" {
  description = "VMSS name"
  value       = azurerm_windows_virtual_machine_scale_set.this.name
}

output "vmss_resource_id" {
  description = "VMSS resource ID"
  value       = azurerm_windows_virtual_machine_scale_set.this.id
}

output "bastion_name" {
  description = "Azure Bastion host name (the shared one when attached)"
  value       = local.bastion_name
}

output "bastion_resource_id" {
  description = "Azure Bastion resource ID (null when attached to an existing network)"
  value       = one(azurerm_bastion_host.this[*].id)
}

output "bastion_public_ip_address" {
  description = "Bastion public IP address (null when attached to an existing network)"
  value       = one(azurerm_public_ip.bastion[*].ip_address)
}

output "admin_username" {
  description = "Local administrator on the VMSS instances"
  value       = var.admin_username
}

output "admin_password" {
  description = "Local administrator password"
  value       = local.admin_password
  sensitive   = true
}

output "rdp_tunnel_via_bastion_hint" {
  description = "Sample command to open a local RDP tunnel (localhost:53389) to the first VMSS instance via Bastion."
  value = format(
    "INSTANCE_ID=$(az vmss list-instances -g %s -n %s --query '[0].id' -o tsv) && az network bastion tunnel --resource-group %s --name %s --target-resource-id \"$INSTANCE_ID\" --resource-port 3389 --port 53389",
    local.resource_group_name,
    azurerm_windows_virtual_machine_scale_set.this.name,
    local.resource_group_name,
    local.bastion_name,
  )
}
