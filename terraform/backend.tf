terraform {
  backend "azurerm" {
    resource_group_name  = "tfstate-rg"
    storage_account_name = "dellistfstate2026"
    container_name       = "tfstate"
    key                  = "adlab.tfstate"
  }
}
