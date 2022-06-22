resource "azurerm_container_registry" "acr" {
  name                   = "${var.resource_prefix}acr"
  resource_group_name    = var.resource_group_name
  location               = var.resource_group_location
  sku                    = "Premium"
  admin_enabled          = true
  anonymous_pull_enabled = true

  tags = var.tags
}