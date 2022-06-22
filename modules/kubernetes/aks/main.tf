# ---------------------------------------------------------------------------------------------------------------------
# CREATES THE AKS CLUSTER
# ---------------------------------------------------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster" "aks" {

  name                = "${var.resource_prefix}aks"
  resource_group_name = var.resource_group_name
  location            = var.resource_group_location
  dns_prefix          = "dns${var.resource_prefix}"

  default_node_pool {
    name                = "agentpool"
    node_count          = 3
    vm_size             = "Standard_DS3_v2"
    type                = "VirtualMachineScaleSets"
    enable_auto_scaling = true
    min_count           = 3
    max_count           = 6
  }

  identity {
    type = "SystemAssigned"
  }

  lifecycle {
    ignore_changes = [
      # Ignore changes to nodes because we have autoscale enabled
      default_node_pool[0].node_count
    ]
  }

  role_based_access_control_enabled = var.enable_rbac

  # If var.enable_rbac is true, enable the oms_agent block for audit logging
  dynamic "oms_agent" {
    for_each = toset(var.enable_rbac ? ["fake"] : [])
    content {
      log_analytics_workspace_id = var.log_ws_resource_id
    }
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------------------------------------------------
# CONFIGURES AUDIT LOGGING IF RBAC ENABLED
# ---------------------------------------------------------------------------------------------------------------------
resource "azurerm_log_analytics_solution" "aks_la" {
  count = var.enable_rbac ? 1 : 0

  solution_name         = "ContainerInsights"
  resource_group_name   = var.resource_group_name
  location              = var.resource_group_location
  workspace_resource_id = var.log_ws_resource_id
  workspace_name        = var.log_ws_resource_name

  plan {
    publisher = "Microsoft"
    product   = "OMSGallery/ContainerInsights"
  }

  tags = var.tags
}

resource "azurerm_monitor_diagnostic_setting" "aks_audit" {
  count = var.enable_rbac ? 1 : 0

  depends_on = [
    azurerm_kubernetes_cluster.aks
  ]

  name                       = "${azurerm_kubernetes_cluster.aks.name}-audit"
  target_resource_id         = azurerm_kubernetes_cluster.aks.id
  log_analytics_workspace_id = var.log_ws_resource_id

  log {
    category = "kube-apiserver"
    enabled  = true

    retention_policy {
      enabled = true
      days    = 7
    }
  }

  log {
    category = "kube-audit"
    enabled  = true

    retention_policy {
      enabled = true
      days    = 7
    }
  }

  log {
    category = "kube-audit-admin"
    enabled  = true

    retention_policy {
      enabled = true
      days    = 7
    }
  }

  log {
    category = "kube-controller-manager"
    enabled  = true

    retention_policy {
      enabled = true
      days    = 7
    }
  }

  log {
    category = "kube-scheduler"
    enabled  = true

    retention_policy {
      enabled = true
      days    = 7
    }
  }

  log {
    category = "cluster-autoscaler"
    enabled  = true

    retention_policy {
      enabled = true
      days    = 7
    }
  }

  log {
    category = "cloud-controller-manager"
    enabled  = true

    retention_policy {
      enabled = true
      days    = 7
    }
  }

  log {
    category = "guard"
    enabled  = true

    retention_policy {
      enabled = true
      days    = 7
    }
  }

  log {
    category = "csi-azuredisk-controller"
    enabled  = true

    retention_policy {
      enabled = true
      days    = 7
    }
  }

  log {
    category = "csi-azurefile-controller"
    enabled  = true

    retention_policy {
      enabled = true
      days    = 7
    }
  }

  log {
    category = "csi-snapshot-controller"
    enabled  = true

    retention_policy {
      enabled = true
      days    = 7
    }
  }

  metric {
    category = "AllMetrics"
    enabled  = true

    retention_policy {
      enabled = true
      days    = 7
    }
  }
}
