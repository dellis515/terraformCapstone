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
