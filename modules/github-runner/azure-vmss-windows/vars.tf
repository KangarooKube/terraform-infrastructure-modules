variable "github_repo" {
  type        = string
  description = "Full HTTPS URL of the GitHub repository (e.g. https://github.com/owner/repo) the runners should register against"
}

variable "github_runner_token" {
  type        = string
  description = "GitHub Actions runner registration token (expires in 1 hour). Passed only through the bootstrap extension's protected settings. Mint a fresh one on each apply via `gh api -X POST /repos/<owner>/<repo>/actions/runners/registration-token --jq .token`."
  sensitive   = true
}

variable "network" {
  type = object({
    resource_group_name           = string
    location                      = string
    virtual_network_name          = string
    bastion_subnet_address_prefix = string
    bastion_name                  = string
  })
  description = "Attach to an existing runner network (pass the Linux module's `network` output). The module then creates only its subnet, NSG and VMSS in that resource group and VNet, behind the existing Bastion. When null, the module creates its own resource group, VNet and Bastion (standalone mode)."
  default     = null
}

variable "resource_group_name" {
  type        = string
  description = "Resource group to create in standalone mode (must NOT pre-exist). Required when network is null; ignored when attached."
  default     = null
}

variable "location" {
  type        = string
  description = "Azure region for standalone mode. Attached mode uses network.location."
  default     = "canadacentral"
}

variable "name_prefix" {
  type        = string
  description = "Prefix for resource names: <prefix>-vmss-runner and <prefix>-nsg-runners, plus <prefix>-vnet, <prefix>-bas and <prefix>-pip-bas in standalone mode. Must differ from the Linux pool's prefix when attached."
  default     = "ghrunner-win"
}

variable "computer_name_prefix" {
  type        = string
  description = "Windows computer name prefix (max 9 characters; Azure appends 6). The runner registers under the computer name. Defaults to name_prefix lowercased, with non-alphanumerics removed, truncated to 9 characters."
  default     = null
  validation {
    condition     = var.computer_name_prefix == null || can(regex("^[a-zA-Z0-9][a-zA-Z0-9-]{0,8}$", var.computer_name_prefix))
    error_message = "computer_name_prefix must be 1-9 alphanumeric or hyphen characters and start with an alphanumeric."
  }
}

variable "runners_subnet_address_prefix" {
  type        = string
  description = "Address prefix of the snet-runners-windows subnet. Must be inside the VNet (10.0.0.0/16) and not overlap the Linux runners (10.0.1.0/24) or Bastion (10.0.2.0/26) subnets."
  default     = "10.0.3.0/24"
}

variable "bastion_public_ip_tags" {
  type        = map(string)
  description = "Standalone mode only: ipTags (ipTagType => tag) on the Bastion public IP. ipTags are immutable in Azure, so changing this replaces the public IP and the Bastion host. Set to {} to omit ipTags; the module then adds the hybrid-vm-migration policy skip tags instead."
  default = {
    FirstPartyUsage = "/NonProd"
  }
}

variable "runner_labels" {
  type        = list(string)
  description = "Custom labels added to the runner. The default 'self-hosted, Windows, X64' set is added by GitHub automatically."
  default     = ["self-hosted-azure"]
}

variable "runner_version" {
  type        = string
  description = "actions/runner release version installed by the bootstrap script (e.g. 2.338.2)"
  default     = "2.338.2"
}

variable "instance_count" {
  type        = number
  description = "Number of VMSS instances (manual scale-out supported)"
  default     = 1
}

variable "instance_sku" {
  type        = string
  description = "VMSS instance SKU. Must support Trusted Launch (Gen2) for the default image."
  default     = "Standard_D8as_v5"
}

variable "os_disk_size_gb" {
  type        = number
  description = "OS disk size in GB (Premium_LRS)"
  default     = 256
}

variable "vm_image" {
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
  description = "Source image for the VMSS instances. Must be a Gen2 image (Trusted Launch is enabled)."
  default = {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2025-datacenter-azure-edition"
    version   = "latest"
  }
}

variable "admin_username" {
  type        = string
  description = "Local administrator on each instance. The runner service logs on as this account so jobs can install tooling."
  default     = "runneradmin"
}

variable "admin_password" {
  type        = string
  description = "Local administrator password. Defaults to a generated 24-character password (see the admin_password output). Limited to letters, digits and -_.@+ because it is passed on the runner configuration command line."
  default     = null
  sensitive   = true
  validation {
    condition     = var.admin_password == null || can(regex("^[A-Za-z0-9_.@+-]{12,123}$", var.admin_password))
    error_message = "admin_password must be 12-123 characters from letters, digits and -_.@+ (and satisfy Azure's complexity rules)."
  }
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
  description = "VMSS upgrade mode: Manual, Automatic, or Rolling. Automatic and Rolling roll model changes out to existing instances and require a health signal to evaluate the rollout (see health_extension_enabled)."
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
  description = "Deploy the Application Health (Windows) extension, provisioned after the bootstrap extension, so Automatic/Rolling upgrades have a real health signal."
  default     = true
}

variable "health_extension" {
  description = "Application Health (Windows) extension probe settings. Used only when health_extension_enabled is true. For protocol http/https a request_path is required. The default tcp:3389 probe treats an instance as healthy whenever RDP is listening."
  type = object({
    protocol     = string
    port         = number
    request_path = optional(string)
  })
  default = {
    protocol = "tcp"
    port     = 3389
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

variable "tool_versions" {
  description = "Versions of the always-installed tools: Git for Windows release tag (without the leading v), PowerShell 7 and GitHub CLI."
  type = object({
    git  = optional(string, "2.56.1.windows.1")
    pwsh = optional(string, "7.6.10")
    gh   = optional(string, "2.106.0")
  })
  default = {}
  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+\\.windows\\.[0-9]+$", var.tool_versions.git))
    error_message = "tool_versions.git must be a Git for Windows tag such as 2.56.1.windows.1."
  }
  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.tool_versions.pwsh)) && can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.tool_versions.gh))
    error_message = "tool_versions.pwsh and tool_versions.gh must be release versions such as 7.6.10 and 2.106.0."
  }
}

variable "install_gh_cli" {
  type        = bool
  description = "Install the GitHub CLI (gh) at machine scope."
  default     = true
}

variable "install_msvc_build_tools" {
  type        = bool
  description = "Install Visual Studio 2022 Build Tools with the VCTools workload and recommended components (MSVC x64/x86 toolset and Windows SDK). Adds roughly 15-20 minutes to first boot."
  default     = false
}

variable "install_rustup" {
  type        = bool
  description = "Install rustup at machine scope (RUSTUP_HOME=C:\\rust\\rustup, CARGO_HOME=C:\\rust\\cargo, cargo bin on PATH) with rust_toolchain as the default toolchain (minimal profile plus clippy and rustfmt)."
  default     = false
}

variable "rust_toolchain" {
  type        = string
  description = "Default rustup toolchain when install_rustup is true (e.g. stable or 1.90.0)."
  default     = "stable"
  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+$", var.rust_toolchain))
    error_message = "rust_toolchain must be a rustup toolchain name such as stable or 1.90.0."
  }
}

variable "extra_bootstrap_script" {
  type        = string
  description = "Optional PowerShell script run as SYSTEM after the base tools are installed. Jobs are held until it finishes. It runs whenever an instance bootstraps (first boot, reimage, or a rerun on an unhealthy instance), so it must be idempotent; a non-zero exit fails the bootstrap. It is delivered through custom_data, so it must not contain secrets."
  default     = ""
}

variable "job_cleanup_enabled" {
  type        = bool
  description = "Install a runner job-completed hook that deletes the job workspace contents. It only touches a workspace strictly beneath the runner work directory and logs, rather than fails the job on, cleanup errors."
  default     = true
}
