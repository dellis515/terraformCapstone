output "resource_group" {
  value = azurerm_resource_group.lab.name
}

output "domain_name" {
  value = var.domain_name
}

output "dc_vm_name" {
  value = azurerm_windows_virtual_machine.dc.name
}

output "dc_private_ip" {
  value = azurerm_network_interface.dc.private_ip_address
}

output "ca_vm_name" {
  value = azurerm_windows_virtual_machine.ca.name
}

output "ca_private_ip" {
  value = azurerm_network_interface.ca.private_ip_address
}

output "iis_vm_name" {
  value = azurerm_windows_virtual_machine.iis.name
}

output "iis_private_ip" {
  value = azurerm_network_interface.iis.private_ip_address
}

output "fs_vm_name" {
  value = azurerm_windows_virtual_machine.fs.name
}

output "fs_private_ip" {
  value = azurerm_network_interface.fs.private_ip_address
}

output "sql_vm_name" {
  value = azurerm_windows_virtual_machine.sql.name
}

output "sql_private_ip" {
  value = azurerm_network_interface.sql.private_ip_address
}

output "w11_vm_name" {
  value = azurerm_windows_virtual_machine.w11.name
}

output "w11_private_ip" {
  value = azurerm_network_interface.w11.private_ip_address
}