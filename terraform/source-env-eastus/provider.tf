provider "azurerm" {
  features {
  }
  subscription_id                 = "c64fd005-b880-4802-9aa8-2dcc75068a20"
  environment                     = "public"
  use_msi                         = false
  use_cli                         = true
  use_oidc                        = false
  resource_provider_registrations = "none"
}
