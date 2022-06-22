variable "resource_prefix" {
  description = "Resource Prefix appended to name"
  type        = string
}

variable "resource_group_name" {
  description = "The resource group in which the deployment is taking place"
  type        = string
}

variable "resource_group_location" {
  description = "The location in which the deployment is taking place"
  type        = string
  default     = "eastus"
}

variable "enable_rbac" {
  description = "If set to true, enable RBAC and Audit Logging"
  type        = bool
  default     = true
}

variable "log_ws_resource_name" {
  description = "Name of the Log Analytics Workspace"
  type        = string
  default     = null
}

variable "log_ws_resource_id" {
  description = "ID of the Log Analytics Workspace"
  type        = string
  default     = "/subscriptions/7d046d65-f60c-45a2-920e-1a9b69ce690e/resourceGroups/fake/providers/Microsoft.OperationalInsights/workspaces/fake"
}

variable "tags" {
  type        = map(string)
  description = "A map of the tags to use on the resources that are deployed with this module."

  default = {
    Source  = "terraform"
    Owner   = "Your Name"
    Project = "Terraform CICD"
  }
}
