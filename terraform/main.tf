terraform {
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

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
}

locals {
  vms = {
    "vm-test-01" = {
      size          = "Standard_D16ds_v6"
      data_disk_gb  = 64
      data_disk_sku = "Premium_LRS"
      zone          = null
    }
    "vm-test-02" = {
      size          = "Standard_D8ds_v6"
      data_disk_gb  = 32
      data_disk_sku = "PremiumV2_LRS"
      zone          = "1"
    }
    "vm-test-03" = {
      size          = "Standard_D2ds_v6"
      data_disk_gb  = 16
      data_disk_sku = "Premium_LRS"
      zone          = null
    }
  }
}
