resource "azurerm_log_analytics_workspace" "log_ws" {

  name                = "${var.resource_prefix}la"
  resource_group_name = var.resource_group_name
  location            = var.resource_group_location
  sku                 = "PerGB2018"

  tags = var.tags

}