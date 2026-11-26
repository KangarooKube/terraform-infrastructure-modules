terraform {
  required_version = ">= 1.7"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

locals {
  standalone = var.network == null

  resource_group_name   = local.standalone ? azurerm_resource_group.rg[0].name : var.network.resource_group_name
  location              = local.standalone ? azurerm_resource_group.rg[0].location : var.network.location
  vnet_name             = local.standalone ? azurerm_virtual_network.vnet[0].name : var.network.virtual_network_name
  bastion_subnet_prefix = local.standalone ? "10.0.2.0/26" : var.network.bastion_subnet_address_prefix
  bastion_name          = local.standalone ? azurerm_bastion_host.this[0].name : var.network.bastion_name

  runners_subnet = "snet-runners-windows"
  nsg_name       = "${var.name_prefix}-nsg-runners"
  vmss_name      = "${var.name_prefix}-vmss-runner"
  computer_name_prefix = coalesce(
    var.computer_name_prefix,
    substr(replace(lower(var.name_prefix), "/[^a-z0-9]/", ""), 0, 9),
  )

  admin_password = coalesce(var.admin_password, random_password.admin.result)

  bootstrap_extension_name = "gh-runner-bootstrap"

  bootstrap_rendered = templatefile("${path.module}/bootstrap-github-runner.ps1.tftpl", {
    github_repo                = replace(var.github_repo, "'", "''")
    runner_labels              = replace(join(",", var.runner_labels), "'", "''")
    runner_version             = var.runner_version
    runner_user                = var.admin_username
    git_version                = var.tool_versions.git
    pwsh_version               = var.tool_versions.pwsh
    gh_version                 = var.tool_versions.gh
    install_gh_cli             = var.install_gh_cli
    install_msvc_build_tools   = var.install_msvc_build_tools
    install_rustup             = var.install_rustup
    rust_toolchain             = var.rust_toolchain
    job_cleanup_enabled        = var.job_cleanup_enabled
    extra_bootstrap_script_b64 = var.extra_bootstrap_script == "" ? "" : base64encode(var.extra_bootstrap_script)
  })

  # Azure writes custom_data to C:\AzureData\CustomData.bin. The extension copies
  # it to a .ps1 and passes the secrets as arguments, so they only ever live in
  # the extension's protected settings.
  bootstrap_command = format(
    "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"Copy-Item -Force -Path C:\\AzureData\\CustomData.bin -Destination C:\\Windows\\Temp\\gh-runner-bootstrap.ps1; & C:\\Windows\\Temp\\gh-runner-bootstrap.ps1 -RunnerToken '%s' -AdminPassword '%s'; exit $LASTEXITCODE\"",
    replace(var.github_runner_token, "'", "''"),
    local.admin_password,
  )

  # Re-run the bootstrap extension whenever the token or the script changes.
  bootstrap_update_tag = nonsensitive(substr(sha256("${var.github_runner_token}|${local.bootstrap_rendered}"), 0, 16))

  bastion_pip_first_party_tagged = contains(keys(var.bastion_public_ip_tags), "FirstPartyUsage")
  bastion_pip_policy_skip_tags = local.bastion_pip_first_party_tagged ? {} : {
    "hybrid-vm-migration-publicip-mustbefirstpartytagged-skip-flag"          = "true"
    "hybrid-vm-migration-publicip-mustbefirstpartytagged-skip-justification" = "Azure Bastion ingress for self-hosted GitHub runner - runner VMSS itself has no public IP"
  }
}

resource "random_password" "admin" {
  length           = 24
  special          = true
  override_special = "-_.@+"
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
}

# ----- Standalone network (only when var.network is null) ---------------------

resource "azurerm_resource_group" "rg" {
  count    = local.standalone ? 1 : 0
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags

  lifecycle {
    precondition {
      condition     = var.resource_group_name != null
      error_message = "resource_group_name is required when network is null (standalone mode)."
    }
  }
}

resource "azurerm_virtual_network" "vnet" {
  count               = local.standalone ? 1 : 0
  name                = "${var.name_prefix}-vnet"
  location            = azurerm_resource_group.rg[0].location
  resource_group_name = azurerm_resource_group.rg[0].name
  address_space       = ["10.0.0.0/16"]
  tags                = var.tags
}

resource "azurerm_subnet" "bastion" {
  count                = local.standalone ? 1 : 0
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.rg[0].name
  virtual_network_name = azurerm_virtual_network.vnet[0].name
  address_prefixes     = [local.bastion_subnet_prefix]
}

resource "azurerm_public_ip" "bastion" {
  count               = local.standalone ? 1 : 0
  name                = "${var.name_prefix}-pip-bas"
  location            = azurerm_resource_group.rg[0].location
  resource_group_name = azurerm_resource_group.rg[0].name
  allocation_method   = "Static"
  sku                 = "Standard"
  ip_tags             = var.bastion_public_ip_tags
  tags                = merge(var.tags, local.bastion_pip_policy_skip_tags)
}

resource "azurerm_bastion_host" "this" {
  count               = local.standalone ? 1 : 0
  name                = "${var.name_prefix}-bas"
  location            = azurerm_resource_group.rg[0].location
  resource_group_name = azurerm_resource_group.rg[0].name
  sku                 = "Standard"
  tags                = var.tags

  copy_paste_enabled     = true
  file_copy_enabled      = false
  ip_connect_enabled     = true
  shareable_link_enabled = false
  tunneling_enabled      = true

  ip_configuration {
    name                 = "configuration"
    subnet_id            = azurerm_subnet.bastion[0].id
    public_ip_address_id = azurerm_public_ip.bastion[0].id
  }
}

# ----- Windows runner subnet + NSG (both modes) -------------------------------

resource "azurerm_subnet" "runners" {
  name                 = local.runners_subnet
  resource_group_name  = local.resource_group_name
  virtual_network_name = local.vnet_name
  address_prefixes     = [var.runners_subnet_address_prefix]
}

resource "azurerm_network_security_group" "runners" {
  name                = local.nsg_name
  location            = local.location
  resource_group_name = local.resource_group_name
  tags                = var.tags

  security_rule {
    name                       = "AllowRdpFromBastion"
    priority                   = 1000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = local.bastion_subnet_prefix
    destination_address_prefix = "*"
    description                = "RDP from AzureBastionSubnet only"
  }

  security_rule {
    name                       = "DenyAllInbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowVnetOutbound"
    priority                   = 1000
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "AllowInternetOutbound"
    priority                   = 1010
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "Internet"
    description                = "Outbound to GitHub and tool download endpoints"
  }
}

resource "azurerm_subnet_network_security_group_association" "runners" {
  subnet_id                 = azurerm_subnet.runners.id
  network_security_group_id = azurerm_network_security_group.runners.id
}

# ----- Windows runner VMSS ----------------------------------------------------

resource "azurerm_windows_virtual_machine_scale_set" "this" {
  name                 = local.vmss_name
  computer_name_prefix = local.computer_name_prefix
  location             = local.location
  resource_group_name  = local.resource_group_name
  sku                  = var.instance_sku
  instances            = var.instance_count
  admin_username       = var.admin_username
  admin_password       = local.admin_password
  tags                 = var.tags

  # Same semantics as the Linux module: Automatic/Rolling roll model changes
  # (a new token re-runs the bootstrap extension) out to existing instances and
  # need the health extension to evaluate the rollout.
  upgrade_mode                = var.upgrade_mode
  single_placement_group      = true
  platform_fault_domain_count = 1
  overprovision               = false
  enable_automatic_updates    = false
  provision_vm_agent          = true
  secure_boot_enabled         = true
  vtpm_enabled                = true

  dynamic "rolling_upgrade_policy" {
    for_each = (contains(["Automatic", "Rolling"], var.upgrade_mode) && var.rolling_upgrade_policy != null) ? [var.rolling_upgrade_policy] : []
    content {
      max_batch_instance_percent              = rolling_upgrade_policy.value.max_batch_instance_percent
      max_unhealthy_instance_percent          = rolling_upgrade_policy.value.max_unhealthy_instance_percent
      max_unhealthy_upgraded_instance_percent = rolling_upgrade_policy.value.max_unhealthy_upgraded_instance_percent
      pause_time_between_batches              = rolling_upgrade_policy.value.pause_time_between_batches
    }
  }

  custom_data = base64encode(local.bootstrap_rendered)

  extension {
    name                       = local.bootstrap_extension_name
    publisher                  = "Microsoft.Compute"
    type                       = "CustomScriptExtension"
    type_handler_version       = "1.10"
    auto_upgrade_minor_version = true
    force_update_tag           = local.bootstrap_update_tag
    protected_settings = jsonencode({
      commandToExecute = local.bootstrap_command
    })
  }

  dynamic "extension" {
    for_each = var.health_extension_enabled ? [var.health_extension] : []
    content {
      name                       = "ApplicationHealthWindows"
      publisher                  = "Microsoft.ManagedServices"
      type                       = "ApplicationHealthWindows"
      type_handler_version       = "1.0"
      auto_upgrade_minor_version = true
      provision_after_extensions = [local.bootstrap_extension_name]
      settings = jsonencode(merge(
        {
          protocol = extension.value.protocol
          port     = extension.value.port
        },
        try(extension.value.request_path, null) == null ? {} : { requestPath = extension.value.request_path }
      ))
    }
  }

  identity {
    type = "SystemAssigned"
  }

  source_image_reference {
    publisher = var.vm_image.publisher
    offer     = var.vm_image.offer
    sku       = var.vm_image.sku
    version   = var.vm_image.version
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.os_disk_size_gb
  }

  network_interface {
    name    = "nic-runners"
    primary = true

    ip_configuration {
      name      = "internal"
      primary   = true
      subnet_id = azurerm_subnet.runners.id
    }
  }

  boot_diagnostics {
    storage_account_uri = null
  }

  depends_on = [
    azurerm_subnet_network_security_group_association.runners,
    azurerm_bastion_host.this,
  ]
}
