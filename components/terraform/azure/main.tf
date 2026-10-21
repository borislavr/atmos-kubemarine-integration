terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
  }
}

# Auth: `az login` (or ARM_* env in CI); subscription: ARM_SUBSCRIPTION_ID from the stack `env`.
provider "azurerm" {
  features {}
}


locals {
  admin_cidrs = compact([var.admin_cidr, var.ci_cidr])
  # cost allocation (Cost Management: group/filter by tag); subnets and NSG associations have no tags
  tags = { "cost-usage" = var.stage }
}

# --- network ---

resource "azurerm_resource_group" "this" {
  name     = "rg-${var.stage}"
  location = var.region
  tags     = local.tags
}

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.stage}"
  location            = var.region
  tags                = local.tags
  resource_group_name = azurerm_resource_group.this.name
  address_space       = [var.cidr]
}

resource "azurerm_subnet" "this" {
  name                 = "snet-${var.stage}"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.cidr]
}

# Default NSG rules already allow VNet-internal traffic and deny inbound from Internet.
resource "azurerm_network_security_group" "this" {
  name                = "nsg-${var.stage}"
  location            = var.region
  tags                = local.tags
  resource_group_name = azurerm_resource_group.this.name
  security_rule {
    name                       = "admin"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = [for p in var.admin_ports : tostring(p)]
    source_address_prefixes    = local.admin_cidrs
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "this" {
  subnet_id                 = azurerm_subnet.this.id
  network_security_group_id = azurerm_network_security_group.this.id
}

# --- compute ---

module "nodes" {
  source     = "../modules/nodes"
  sizes      = var.sizes
  node_types = var.node_types
  nodes      = var.nodes
}

resource "azurerm_public_ip" "node" {
  for_each            = module.nodes.nodes
  name                = "pip-${var.stage}-${each.key}"
  location            = var.region
  tags                = local.tags
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "node" {
  for_each            = module.nodes.nodes
  name                = "nic-${var.stage}-${each.key}"
  location            = var.region
  tags                = local.tags
  resource_group_name = azurerm_resource_group.this.name
  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.this.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.node[each.key].id
  }
}

resource "azurerm_linux_virtual_machine" "node" {
  for_each              = module.nodes.nodes
  name                  = "${var.stage}-${each.key}"
  location              = var.region
  tags                  = local.tags
  resource_group_name   = azurerm_resource_group.this.name
  size                  = each.value.size
  admin_username        = "ubuntu"
  network_interface_ids = [azurerm_network_interface.node[each.key].id]
  admin_ssh_key {
    username   = "ubuntu"
    public_key = file(pathexpand(var.ssh_public_key_file))
  }
  os_disk {
    name                 = "osdisk-${var.stage}-${each.key}"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = each.value.disk_size
  }
  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
}
