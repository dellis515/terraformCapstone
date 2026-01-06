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

output "iis_vm_name" {
  value = azurerm_windows_virtual_machine.iis.name
}

output "iis_private_ip" {
  value = azurerm_network_interface.iis.private_ip_address
}
