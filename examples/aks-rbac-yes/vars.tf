variable "resource_prefix" {
  type = string
}

variable "location" {
  type    = string
  default = "eastus"
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