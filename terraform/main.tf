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

locals {
  domain_join = "${var.scripts_base_url}/member-domain-join.ps1${var.scripts_sas}"
  patch_all = "${var.scripts_base_url}/patch-all.ps1${var.scripts_sas}"
  dc_config = "${var.scripts_base_url}/dc-config.ps1${var.scripts_sas}"
  fs_config = "${var.scripts_base_url}/fs-config.ps1${var.scripts_sas}"
  iis_config = "${var.scripts_base_url}/iis-config.ps1${var.scripts_sas}"
  ca_config = "${var.scripts_base_url}/ca-config-runcommand.ps1${var.scripts_sas}"
  ca_bootstrap = "${var.scripts_base_url}/ca-bootstrap-schtask.ps1${var.scripts_sas}"
}

# NETWORK

resource "azurerm_resource_group" "lab" {
  name     = "${var.prefix}-rg"
  location = var.location
}

resource "azurerm_virtual_network" "lab" {
  name                = "${var.prefix}-vnet"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  address_space       = ["10.0.0.0/16"]

  dns_servers = ["10.0.0.4", "8.8.8.8"]
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

  depends_on = [
    azurerm_subnet.lab,
    azurerm_network_security_group.lab
  ]
}

# DC

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
  size                = "Standard_D2s_v3"

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
  name                 = "dc-config"
  virtual_machine_id   = azurerm_windows_virtual_machine.dc.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"

  settings = jsonencode({
    fileUris = [
      local.dc_config
    ]
    commandToExecute = "powershell -ExecutionPolicy Bypass -File .\\dc-config.ps1"
  })
}

# DELAY

resource "random_uuid" "dc_wait_nonce" {}

resource "time_sleep" "wait_for_dc_ready" {
  depends_on      = [azurerm_virtual_machine_extension.dc_config]
  create_duration = "300s"

  triggers = {
    nonce = random_uuid.dc_wait_nonce.result
  }
}


# CA SERVER

resource "azurerm_network_interface" "ca" {
  name                = "${var.prefix}-ca-nic"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.lab.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.0.5"
  }
}

resource "azurerm_windows_virtual_machine" "ca" {
  name                = "${var.prefix}-ca01"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  size                = "Standard_D2s_v3"

  admin_username = var.admin_username
  admin_password = var.admin_password

  network_interface_ids = [azurerm_network_interface.ca.id]

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

resource "azurerm_virtual_machine_extension" "ca_domain_join" {
  name                 = "ca-join-domain"
  virtual_machine_id   = azurerm_windows_virtual_machine.ca.id
  publisher            = "Microsoft.Compute"
  type                 = "JsonADDomainExtension"
  type_handler_version = "1.3"

  settings = jsonencode({
    Name    = var.domain_name
    User    = "${var.domain_netbios}\\${var.admin_username}"
    Restart = "true"
    Options = "3"
  })

  protected_settings = jsonencode({
    Password = var.admin_password
  })

  depends_on = [
    time_sleep.wait_for_dc_ready
  ]
}

resource "azurerm_virtual_machine_run_command" "ca_prereq" {
  name               = "ca-prereq"
  location           = azurerm_resource_group.lab.location
  virtual_machine_id = azurerm_windows_virtual_machine.ca.id

  source {
    script = <<-PS1
      Set-Service seclogon -StartupType Manual
      Start-Service seclogon
      Get-Service seclogon | Select Name, Status, StartType
    PS1
  }

  depends_on = [
    azurerm_virtual_machine_extension.ca_domain_join
  ]
}

resource "azurerm_virtual_machine_extension" "ca_config" {
  name                 = "ca-config"
  virtual_machine_id   = azurerm_windows_virtual_machine.ca.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"

  settings = jsonencode({
    fileUris = [
      local.ca_config,
      local.ca_bootstrap
    ]
  })

  protected_settings = jsonencode({
    commandToExecute = "powershell.exe -ExecutionPolicy Bypass -NoProfile -File .\\ca-bootstrap-schtask.ps1 -DomainNetbios \"${var.domain_netbios}\" -DomainUser \"labadmin\" -DomainPassword \"${var.admin_password}\" -DomainFqdn \"${var.domain_name}\" -DcIp \"10.0.0.4\" -ScriptPath \".\\ca-config-runcommand.ps1\""
  })

  depends_on = [
    azurerm_virtual_machine_run_command.ca_prereq
  ]
}

resource "azurerm_virtual_machine_run_command" "ca_patch" {
  name               = "ca-patch"
  location           = azurerm_resource_group.lab.location
  virtual_machine_id = azurerm_windows_virtual_machine.ca.id

  source {
    script = <<-PS1
      Install-PackageProvider NuGet -Force
      Install-Module PSWindowsUpdate -Force
      Import-Module PSWindowsUpdate
      Get-WindowsUpdate -AcceptAll -Install -AutoReboot
    PS1
  }

  depends_on = [
    azurerm_virtual_machine_extension.ca_config
  ]
}


# IIS SERVER

resource "azurerm_network_interface" "iis" {
  name                = "${var.prefix}-iis-nic"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.lab.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.0.6"
  }
}

resource "azurerm_windows_virtual_machine" "iis" {
  name                = "${var.prefix}-iis01"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  size                = "Standard_D2s_v3"

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

resource "azurerm_virtual_machine_extension" "iis_domain_join" {
  name                 = "iis-join-domain"
  virtual_machine_id   = azurerm_windows_virtual_machine.iis.id
  publisher            = "Microsoft.Compute"
  type                 = "JsonADDomainExtension"
  type_handler_version = "1.3"

  settings = jsonencode({
    Name    = var.domain_name
    User    = "${var.domain_netbios}\\${var.admin_username}"
    Restart = "true"
    Options = "3"
  })

  protected_settings = jsonencode({
    Password = var.admin_password
  })

  depends_on = [
    time_sleep.wait_for_dc_ready
  ]
}

resource "azurerm_virtual_machine_extension" "iis_config" {
  name                 = "iis-config"
  virtual_machine_id   = azurerm_windows_virtual_machine.iis.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"

  settings = jsonencode({
    fileUris = [
      local.iis_config,
      local.patch_all
    ]
  })


  protected_settings = jsonencode({
    commandToExecute = "powershell.exe -ExecutionPolicy Bypass -NoProfile -Command \"& .\\iis-config.ps1; & .\\patch-all.ps1\""

    depends_on = [
      azurerm_virtual_machine_extension.iis_domain_join
    ]
  })
}

# FILE SERVER

resource "azurerm_network_interface" "fs" {
  name                = "dellislab-fs-nic"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.lab.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.0.7"
  }
}

resource "azurerm_windows_virtual_machine" "fs" {
  name                = "dellislab-fs01"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  size                = "Standard_D2s_v3"

  admin_username = var.admin_username
  admin_password = var.admin_password

  network_interface_ids = [
    azurerm_network_interface.fs.id
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
}

resource "azurerm_virtual_machine_extension" "fs_domain_join" {
  name                 = "fs-join-domain"
  virtual_machine_id   = azurerm_windows_virtual_machine.fs.id
  publisher            = "Microsoft.Compute"
  type                 = "JsonADDomainExtension"
  type_handler_version = "1.3"

  settings = jsonencode({
    Name    = var.domain_name
    User    = "${var.domain_netbios}\\${var.admin_username}"
    Restart = "true"
    Options = "3"
  })

  protected_settings = jsonencode({
    Password = var.admin_password
  })

  depends_on = [
    time_sleep.wait_for_dc_ready
  ]
}

resource "azurerm_virtual_machine_extension" "fs_config" {
  name                 = "fs-config"
  virtual_machine_id   = azurerm_windows_virtual_machine.fs.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"

  settings = jsonencode({
    fileUris = [
      local.fs_config,
      local.patch_all
    ]

    commandToExecute = "powershell.exe -ExecutionPolicy Bypass -NoProfile -Command \"& .\\fs-config.ps1; & .\\patch-all.ps1\""
  })

  depends_on = [
    azurerm_virtual_machine_extension.fs_domain_join
  ]
}

# SQL SERVER

resource "azurerm_network_interface" "sql" {
  name                = "dellislab-sql-nic"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.lab.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.0.8"
  }
}

resource "azurerm_windows_virtual_machine" "sql" {
  name                = "dellislab-sql01"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  size                = "Standard_D2s_v3"

  admin_username = var.admin_username
  admin_password = var.admin_password

  network_interface_ids = [
    azurerm_network_interface.sql.id
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftSQLServer"
    offer     = "SQL2022-WS2022"
    sku       = "sqldev-gen2"
    version   = "latest"
  }
}

resource "azurerm_virtual_machine_extension" "sql_domain_join" {
  name                 = "sql-join-domain"
  virtual_machine_id   = azurerm_windows_virtual_machine.sql.id
  publisher            = "Microsoft.Compute"
  type                 = "JsonADDomainExtension"
  type_handler_version = "1.3"

  settings = jsonencode({
    Name    = var.domain_name
    User    = "${var.domain_netbios}\\${var.admin_username}"
    Restart = "true"
    Options = "3"
  })

  protected_settings = jsonencode({
    Password = var.admin_password
  })

  depends_on = [
    time_sleep.wait_for_dc_ready
  ]
}

resource "azurerm_mssql_virtual_machine" "sql01" {
  virtual_machine_id = azurerm_windows_virtual_machine.sql.id
  sql_license_type   = "PAYG"

  depends_on = [
    azurerm_virtual_machine_extension.sql_domain_join
  ]
}

# WINDOWS 11

resource "azurerm_network_interface" "w11" {
  name                = "dellislab-w11-nic"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.lab.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.0.11"
  }
}

resource "azurerm_windows_virtual_machine" "w11" {
  name                = "dellislab-w11"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  size                = "Standard_D2s_v3"

  admin_username = var.admin_username
  admin_password = var.admin_password

  network_interface_ids = [
    azurerm_network_interface.w11.id
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsDesktop"
    offer     = "windows-11"
    sku       = "win11-25h2-pro"
    version   = "latest"
  }

  secure_boot_enabled = true
  vtpm_enabled = true
}

resource "azurerm_virtual_machine_extension" "w11_domain_join" {
  name                 = "w11-join-domain"
  virtual_machine_id   = azurerm_windows_virtual_machine.w11.id
  publisher            = "Microsoft.Compute"
  type                 = "JsonADDomainExtension"
  type_handler_version = "1.3"

  settings = jsonencode({
    Name    = var.domain_name
    User    = "${var.domain_netbios}\\${var.admin_username}"
    Restart = "true"
    Options = "3"
  })

  protected_settings = jsonencode({
    Password = var.admin_password
  })

  depends_on = [
    time_sleep.wait_for_dc_ready
  ]
}

resource "azurerm_virtual_machine_extension" "w11_config" {
  name                 = "w11-config"
  virtual_machine_id   = azurerm_windows_virtual_machine.w11.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"

  settings = jsonencode({
    fileUris = [
      local.patch_all
    ]

    commandToExecute = "powershell.exe -ExecutionPolicy Bypass -NoProfile -Command \"& .\\patch-all.ps1\""
  })

  depends_on = [
    azurerm_virtual_machine_extension.w11_domain_join
  ]
}

# BASTION

resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name

  address_prefixes = ["10.0.255.0/27"]
}

resource "azurerm_public_ip" "bastion" {
  name                = "dellislab-bastion-pip"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  allocation_method = "Static"
  sku               = "Standard"
}

resource "azurerm_bastion_host" "lab" {
  name                = "dellislab-bastion"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  sku = "Basic"

  ip_configuration {
    name                 = "bastion-ipconfig"
    subnet_id            = azurerm_subnet.bastion.id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }

  depends_on = [
    azurerm_subnet.bastion,
    azurerm_public_ip.bastion,
    time_sleep.wait_for_dc_ready
  ]
}

output "bastion_name" {
  value = azurerm_bastion_host.lab.name
}