# VM Linux (IaaS) com o laboratório completo: cloud-init instala Docker/Make,
# clona este repositório e executa `make up`.
terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.10"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

locals {
  tags = { projeto = "frota", ambiente = "laboratorio" }
}

resource "random_password" "grafana" {
  length  = 20
  special = false
}

resource "azurerm_resource_group" "frota" {
  name     = "${var.prefixo}-rg"
  location = var.location
  tags     = local.tags
}

# ---------- Rede ----------
resource "azurerm_virtual_network" "frota" {
  name                = "${var.prefixo}-vnet"
  address_space       = ["10.20.0.0/16"]
  location            = azurerm_resource_group.frota.location
  resource_group_name = azurerm_resource_group.frota.name
  tags                = local.tags
}

resource "azurerm_subnet" "frota" {
  name                 = "${var.prefixo}-subnet"
  resource_group_name  = azurerm_resource_group.frota.name
  virtual_network_name = azurerm_virtual_network.frota.name
  address_prefixes     = ["10.20.1.0/24"]
}

resource "azurerm_public_ip" "frota" {
  name                = "${var.prefixo}-ip"
  location            = azurerm_resource_group.frota.location
  resource_group_name = azurerm_resource_group.frota.name
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = var.dns_label
  tags                = local.tags
}

# Somente 22 (SSH), 80 (Nginx/APIs) e 3000 (Grafana) entram. Redpanda (9092), Redis (6379),
# PostgreSQL (5432) e o Redpanda Console (8088, só em 127.0.0.1) não têm regra: o
# DenyAllInBound padrão do NSG os bloqueia, e no Compose eles nem publicam porta no host.
resource "azurerm_network_security_group" "frota" {
  name                = "${var.prefixo}-nsg"
  location            = azurerm_resource_group.frota.location
  resource_group_name = azurerm_resource_group.frota.name
  tags                = local.tags

  security_rule {
    name                       = "allow-ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.ssh_origem_permitida
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-http-lb"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-grafana"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3000"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface" "frota" {
  name                = "${var.prefixo}-nic"
  location            = azurerm_resource_group.frota.location
  resource_group_name = azurerm_resource_group.frota.name
  tags                = local.tags

  ip_configuration {
    name                          = "principal"
    subnet_id                     = azurerm_subnet.frota.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.frota.id
  }
}

resource "azurerm_network_interface_security_group_association" "frota" {
  network_interface_id      = azurerm_network_interface.frota.id
  network_security_group_id = azurerm_network_security_group.frota.id
}

# ---------- VM ----------
resource "azurerm_linux_virtual_machine" "frota" {
  name                  = "${var.prefixo}-vm"
  location              = azurerm_resource_group.frota.location
  resource_group_name   = azurerm_resource_group.frota.name
  size                  = var.vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.frota.id]
  tags                  = local.tags

  disable_password_authentication = true
  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = var.disco_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  custom_data = base64encode(templatefile("${path.module}/cloud-init.yaml.tftpl", {
    admin_username         = var.admin_username
    infra_repo_url         = var.infra_repo_url
    infra_repo_branch      = var.infra_repo_branch
    grafana_admin_password = random_password.grafana.result
    sim_num_veiculos       = var.sim_num_veiculos
    sim_intervalo_segundos = var.sim_intervalo_segundos
  }))
}
