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

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
  numeric = true
}

locals {
  name_suffix    = random_string.suffix.result
  vnet_name      = "${var.name_prefix}-vnet"
  runners_subnet = "snet-runners"
  bastion_subnet = "AzureBastionSubnet"
  nsg_name       = "${var.name_prefix}-nsg-runners"
  bastion_name   = "${var.name_prefix}-bas"
  bastion_pip    = "${var.name_prefix}-pip-bas"
  vmss_name      = "${var.name_prefix}-vmss-runner"

  bootstrap_script = file("${path.module}/bootstrap-github-runner.sh")

  cloud_init_rendered = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    github_repo          = var.github_repo
    github_runner_token  = var.github_runner_token
    runner_labels        = join(",", var.runner_labels)
    runner_version       = var.runner_version
    runner_user          = var.admin_username
    bootstrap_script_b64 = base64encode(local.bootstrap_script)
  })
}

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "vnet" {
  name                = local.vnet_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
  tags                = var.tags
}

resource "azurerm_subnet" "runners" {
  name                 = local.runners_subnet
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "bastion" {
  name                 = local.bastion_subnet
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/26"]
}

resource "azurerm_network_security_group" "runners" {
  name                = local.nsg_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = var.tags

  security_rule {
    name                       = "AllowSshFromBastion"
    priority                   = 1000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "10.0.2.0/26"
    destination_address_prefix = "*"
    description                = "SSH from AzureBastionSubnet only"
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
    description                = "Outbound to GitHub, Docker registries, apt mirrors"
  }
}

resource "azurerm_subnet_network_security_group_association" "runners" {
  subnet_id                 = azurerm_subnet.runners.id
  network_security_group_id = azurerm_network_security_group.runners.id
}

resource "azurerm_public_ip" "bastion" {
  name                = local.bastion_pip
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = "${var.name_prefix}-bas-${local.name_suffix}"

  # Skip the `hybrid-vm-migration-publicip-mustbefirstpartytagged` policy.
  # The policy denies PIPs without ipTags of FirstPartyUsage, but exempts
  # resources tagged with both skip-flag and skip-justification.
  tags = merge(var.tags, {
    "hybrid-vm-migration-publicip-mustbefirstpartytagged-skip-flag"          = "true"
    "hybrid-vm-migration-publicip-mustbefirstpartytagged-skip-justification" = "Azure Bastion ingress for self-hosted GitHub runner — runner VMSS itself has no public IP"
  })
}

resource "azurerm_bastion_host" "this" {
  name                = local.bastion_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Standard"
  tags                = var.tags

  copy_paste_enabled     = true
  file_copy_enabled      = false
  ip_connect_enabled     = true
  shareable_link_enabled = false
  tunneling_enabled      = true

  ip_configuration {
    name                 = "configuration"
    subnet_id            = azurerm_subnet.bastion.id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }
}

resource "azurerm_linux_virtual_machine_scale_set" "this" {
  name                = local.vmss_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = var.instance_sku
  instances           = var.instance_count
  admin_username      = var.admin_username
  tags                = var.tags

  # upgrade_mode drives how Terraform model changes (e.g. new custom_data
  # because gh api minted a fresh registration token) reach existing instances.
  # Automatic/Rolling roll the new model out via reimage (re-running cloud-init,
  # which re-registers the runner with the latest token) but require a health
  # signal to evaluate the rollout — enable health_extension_enabled for those
  # modes. Manual leaves existing instances untouched until manually upgraded.
  upgrade_mode                    = var.upgrade_mode
  single_placement_group          = true
  platform_fault_domain_count     = 1
  disable_password_authentication = true
  overprovision                   = false

  # Only valid for Automatic/Rolling upgrade modes; Azure rejects the block for
  # Manual. Set var.rolling_upgrade_policy to null to omit it explicitly.
  dynamic "rolling_upgrade_policy" {
    for_each = (contains(["Automatic", "Rolling"], var.upgrade_mode) && var.rolling_upgrade_policy != null) ? [var.rolling_upgrade_policy] : []
    content {
      max_batch_instance_percent              = rolling_upgrade_policy.value.max_batch_instance_percent
      max_unhealthy_instance_percent          = rolling_upgrade_policy.value.max_unhealthy_instance_percent
      max_unhealthy_upgraded_instance_percent = rolling_upgrade_policy.value.max_unhealthy_upgraded_instance_percent
      pause_time_between_batches              = rolling_upgrade_policy.value.pause_time_between_batches
    }
  }

  # Application Health (Linux) extension: gives Azure a real per-instance health
  # signal so Automatic/Rolling upgrades can proceed instead of treating every
  # instance as unhealthy.
  dynamic "extension" {
    for_each = var.health_extension_enabled ? [var.health_extension] : []
    content {
      name                       = "ApplicationHealthLinux"
      publisher                  = "Microsoft.ManagedServices"
      type                       = "ApplicationHealthLinux"
      type_handler_version       = "1.0"
      auto_upgrade_minor_version = true
      settings = jsonencode(merge(
        {
          protocol = extension.value.protocol
          port     = extension.value.port
        },
        try(extension.value.request_path, null) == null ? {} : { requestPath = extension.value.request_path }
      ))
    }
  }

  custom_data = base64encode(local.cloud_init_rendered)

  identity {
    type = "SystemAssigned"
  }

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
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
