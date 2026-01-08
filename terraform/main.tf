terraform {
  required_version = ">= 1.8.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
}

#NETWORK

resource "azurerm_resource_group" "lab" {
  name     = "${var.prefix}-rg"
  location = var.location
}

resource "azurerm_virtual_network" "lab" {
  name                = "${var.prefix}-vnet"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "lab" {
  name                 = "default"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = ["10.0.0.0/24"]
}

resource "azurerm_network_security_group" "lab" {
  name                = "${var.prefix}-nsg"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  security_rule {
    name                       = "Allow-RDP"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "*"
    destination_port_range     = "3389"
    source_port_range          = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "lab" {
  subnet_id                 = azurerm_subnet.lab.id
  network_security_group_id = azurerm_network_security_group.lab.id
}

#DC

resource "azurerm_network_interface" "dc" {
  name                = "${var.prefix}-dc-nic"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.lab.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.0.4"
  }
}

resource "azurerm_windows_virtual_machine" "dc" {
  name                = "${var.prefix}-dc01"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  size                = "Standard_DS2_v2"

  admin_username = var.admin_username
  admin_password = var.admin_password

  network_interface_ids = [azurerm_network_interface.dc.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-Datacenter"
    version   = "latest"
  }

  automatic_updates_enabled = true
}

resource "azurerm_virtual_machine_extension" "dc_config" {
  name               = "dc-config"
  virtual_machine_id = azurerm_windows_virtual_machine.dc.id
  publisher          = "Microsoft.Compute"
  type               = "CustomScriptExtension"
  type_handler_version = "1.10"

  settings = jsonencode({
    commandToExecute = "powershell -ExecutionPolicy Bypass -File dc-config.ps1"
  })
}

#IIS SERVER

resource "azurerm_network_interface" "iis" {
  name                = "${var.prefix}-iis-nic"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.lab.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.0.10"
  }
}

resource "azurerm_windows_virtual_machine" "iis" {
  name                = "${var.prefix}-iis01"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  size                = "Standard_DS2_v2"

  admin_username = var.admin_username
  admin_password = var.admin_password

  network_interface_ids = [
    azurerm_network_interface.iis.id
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-Datacenter"
    version   = "latest"
  }

  automatic_updates_enabled = true
}


resource "azurerm_virtual_machine_extension" "iis_join" {
  name               = "iis-join-domain"
  virtual_machine_id = azurerm_windows_virtual_machine.iis.id
  publisher          = "Microsoft.Compute"
  type               = "CustomScriptExtension"
  type_handler_version = "1.10"

  settings = jsonencode({
    commandToExecute = "powershell -ExecutionPolicy Bypass -File member-join-domain.ps1"
  })
}

resource "azurerm_virtual_machine_extension" "iis_config" {
  name               = "iis-config"
  virtual_machine_id = azurerm_windows_virtual_machine.iis.id
  publisher          = "Microsoft.Compute"
  type               = "CustomScriptExtension"
  type_handler_version = "1.10"

  settings = jsonencode({
    commandToExecute = "powershell -ExecutionPolicy Bypass -File iis-config.ps1; powershell -File patch-all.ps1"
  })
}