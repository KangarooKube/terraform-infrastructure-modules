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
  description = "Prefix prepended to every resource name (vnet, nsg, bastion, vmss, pip). Keep short — Azure caps several resource name lengths."
  default     = "ghrunner"
}

variable "github_repo" {
  type        = string
  description = "Full HTTPS URL of the GitHub repository (e.g. https://github.com/owner/repo) the runners should register against"
}

variable "github_runner_token" {
  type        = string
  description = "GitHub Actions runner registration token (expires in 1 hour). Mint a fresh one on each apply via `gh api -X POST /repos/<owner>/<repo>/actions/runners/registration-token --jq .token`."
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

variable "runner_version" {
  type        = string
  description = "actions/runner release version installed by the bootstrap script (e.g. 2.338.2)"
  default     = "2.338.2"
}

variable "bastion_public_ip_tags" {
  type        = map(string)
  description = "ipTags (ipTagType => tag) on the Bastion public IP. ipTags are immutable in Azure, so changing this replaces the public IP and the Bastion host. Set to {} to omit ipTags; the module then adds the hybrid-vm-migration policy skip tags instead."
  default = {
    FirstPartyUsage = "/NonProd"
  }
}

variable "extra_apt_packages" {
  type        = list(string)
  description = "Additional apt packages installed on every instance after the base toolchain (git, git-lfs, python3, python3-venv, python3-pip, openssl, build-essential, jq, curl, wget, unzip, zip, rsync, xz-utils, zstd)."
  default     = []
  validation {
    condition     = alltrue([for p in var.extra_apt_packages : can(regex("^[a-z0-9][a-z0-9+.:=~-]*$", p))])
    error_message = "extra_apt_packages entries must be plain apt package names (optionally pinned with =version)."
  }
}

variable "extra_bootstrap_script" {
  type        = string
  description = "Optional bash script run as root on every instance after the base packages and Docker are installed and before the runner registers. A non-zero exit fails the bootstrap. It is delivered through custom_data, so it must not contain secrets."
  default     = ""
}

variable "job_cleanup_enabled" {
  type        = bool
  description = "Install runner job hooks that reset the workspace between jobs: the job-started hook takes ownership of the job workspace (root-owned files left by containers), and the job-completed hook removes all Docker containers, prunes unused networks and anonymous volumes, and deletes the workspace contents. Cleanup only touches a workspace strictly beneath the runner work directory, and each instance hosts a single runner, so Docker-wide cleanup cannot affect another runner."
  default     = true
}

variable "instance_count" {
  type        = number
  description = "Number of VMSS instances (manual scale-out supported)"
  default     = 2
}

variable "instance_sku" {
  type        = string
  description = "VMSS instance SKU"
  default     = "Standard_E32as_v4"
}

variable "os_disk_size_gb" {
  type        = number
  description = "OS disk size in GB"
  default     = 1024
}

variable "vm_image" {
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
  description = "Source image for the VMSS instances"
  default = {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}

variable "admin_username" {
  type        = string
  description = "Admin username on each VMSS instance"
  default     = "azureuser"
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to every resource"
  default = {
    purpose = "github-actions-runner"
    managed = "terraform"
  }
}

variable "upgrade_mode" {
  type        = string
  description = "VMSS upgrade mode: Manual, Automatic, or Rolling. Automatic and Rolling roll model changes out to existing instances and require a health signal to evaluate the rollout (see health_extension_enabled); without one Azure treats every instance as unhealthy and the rolling upgrade fails before the first batch."
  default     = "Automatic"
  validation {
    condition     = contains(["Manual", "Automatic", "Rolling"], var.upgrade_mode)
    error_message = "upgrade_mode must be one of: Manual, Automatic, Rolling."
  }
}

variable "rolling_upgrade_policy" {
  description = "Rolling upgrade policy block. Applied only when upgrade_mode is Automatic or Rolling (it is invalid for Manual). Set to null to omit the block entirely."
  type = object({
    max_batch_instance_percent              = number
    max_unhealthy_instance_percent          = number
    max_unhealthy_upgraded_instance_percent = number
    pause_time_between_batches              = string
  })
  default = {
    max_batch_instance_percent              = 50
    max_unhealthy_instance_percent          = 50
    max_unhealthy_upgraded_instance_percent = 50
    pause_time_between_batches              = "PT2M"
  }
}

variable "health_extension_enabled" {
  type        = bool
  description = "Deploy the Application Health (Linux) extension so Automatic/Rolling upgrades have a real health signal. Strongly recommended whenever upgrade_mode is Automatic or Rolling."
  default     = false
}

variable "health_extension" {
  description = "Application Health (Linux) extension probe settings. Used only when health_extension_enabled is true. For protocol http/https a request_path is required; the endpoint must return 200 for the instance to be reported healthy. The default tcp:22 probe treats an instance as healthy whenever sshd is reachable."
  type = object({
    protocol     = string
    port         = number
    request_path = optional(string)
  })
  default = {
    protocol = "tcp"
    port     = 22
  }
  validation {
    condition     = contains(["tcp", "http", "https"], var.health_extension.protocol)
    error_message = "health_extension.protocol must be one of: tcp, http, https."
  }
  validation {
    condition     = var.health_extension.protocol == "tcp" || try(var.health_extension.request_path, null) != null
    error_message = "health_extension.request_path is required when protocol is http or https."
  }
}
