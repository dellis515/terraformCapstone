variable "prefix" {
  description = "Prefix for all Azure resources"
  type        = string
  default     = "dellislab"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "eastus"
}

variable "admin_username" {
  description = "Local administrator username for all VMs"
  type        = string
}

variable "admin_password" {
  description = "Local administrator password"
  type        = string
  sensitive   = true
}

variable "domain_name" {
  description = "Active Directory domain FQDN"
  type        = string
  default     = "dellis.lab"
}

variable "domain_netbios" {
  description = "Active Directory NetBIOS name"
  type        = string
  default     = "DELLIS"
}

variable "scripts_base_url" {
  type        = string
  description = "Base URL to scripts container, no SAS"
  default = "https://dellislabscripts.blob.core.windows.net/scripts"
}

variable "scripts_sas" {
  type        = string
  description = "SAS query string INCLUDING leading '?'"
  default = "?sp=rl&st=2026-01-13T01:02:39Z&se=2026-02-02T09:17:39Z&spr=https&sv=2024-11-04&sr=c&sig=k%2FyytU60C3Dcxyiz3Drnzk3dzZvSaL3zYxb8suY9T5A%3D"
}
