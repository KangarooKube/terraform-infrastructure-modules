variable "resource_group_name" {
  type        = string
  description = "Resource group to create for runner infrastructure (must NOT pre-exist)"
}

variable "location" {
  type        = string
  description = "Azure region"
  default     = "canadacentral"
}

variable "name_prefix" {
  type        = string
  description = "Prefix prepended to every resource name (vnet, nsg, bastion, vmss, pip)"
  default     = "ghrunner"
}

variable "github_repo" {
  type        = string
  description = "Full HTTPS URL of the GitHub repository the runners should register against (e.g. https://github.com/owner/repo)"
}

variable "github_runner_token" {
  type        = string
  description = "GitHub Actions runner registration token (expires in 1 hour)"
  sensitive   = true
}

variable "ssh_public_key" {
  type        = string
  description = "Public SSH key (OpenSSH format) authorized for the admin user on the VMSS instances"
  sensitive   = true
}

variable "runner_labels" {
  type        = list(string)
  description = "Custom labels added to the runner. The default 'self-hosted, Linux, X64' set is added by GitHub automatically."
  default     = ["self-hosted-azure"]
}

variable "instance_count" {
  type        = number
  description = "Number of VMSS instances"
  default     = 2
}

variable "instance_sku" {
  type        = string
  description = "VMSS instance SKU"
  default     = "Standard_E32as_v4"
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to every resource"
  default = {
    Source  = "terraform"
    Owner   = "Your Name"
    Project = "GitHub self-hosted runner example"
  }
}
