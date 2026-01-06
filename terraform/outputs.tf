output "resource_group" {
  value = azurerm_resource_group.lab.name
}

output "dc_private_ip" {
  value = azurerm_network_interface.dc.private_ip_address
}

output "iis_private_ip" {
  value = azurerm_network_interface.iis.private_ip_address
}

output "domain_name" {
  value = var.domain_name
}
