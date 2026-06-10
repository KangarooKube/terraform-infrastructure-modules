module "github_runner_azure_vmss" {
  source = "../../modules/github-runner/azure-vmss"

  resource_group_name = var.resource_group_name
  location            = var.location
  name_prefix         = var.name_prefix
  github_repo         = var.github_repo
  github_runner_token = var.github_runner_token
  ssh_public_key      = var.ssh_public_key
  runner_labels       = var.runner_labels
  instance_count      = var.instance_count
  instance_sku        = var.instance_sku
  tags                = var.tags
}
