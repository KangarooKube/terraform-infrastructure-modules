module "resource_group" {
  source          = "../../modules/misc/resource-group"
  resource_prefix = var.resource_prefix
  location        = var.location
  tags            = var.tags
}

module "log_ws" {
  depends_on = [module.resource_group]
  source     = "../../modules/monitoring/log-analytics"
  resource_prefix = var.resource_prefix
  resource_group_name = module.resource_group.resource_group_name
  resource_group_location = module.resource_group.resource_group_location
  tags = var.tags
}

module "acr" {
  depends_on = [module.resource_group]
  source     = "../../modules/kubernetes/acr"
  resource_prefix = var.resource_prefix
  resource_group_name = module.resource_group.resource_group_name
  resource_group_location = module.resource_group.resource_group_location
  tags = var.tags
}

module "aks" {
  depends_on = [module.resource_group, module.log_ws]
  source     = "../../modules/kubernetes/aks"
  resource_prefix = var.resource_prefix
  resource_group_name = module.resource_group.resource_group_name
  resource_group_location = module.resource_group.resource_group_location
  enable_rbac = true
  log_ws_resource_name = module.log_ws.log_ws_resource_name
  log_ws_resource_id = module.log_ws.log_ws_resource_id
  tags = var.tags
}

resource "local_file" "kubeconfig" {
  depends_on = [module.aks]
  content  = module.aks.kube_config_raw
  filename = "kubeconfig"
}