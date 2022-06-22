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

variable "tags" {
  type        = map(string)
  description = "A map of the tags to use on the resources that are deployed with this module."

  default = {
    Source  = "terraform"
    Owner   = "Your Name"
    Project = "Terraform CICD"
  }
}
