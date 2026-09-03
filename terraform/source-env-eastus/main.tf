resource "azurerm_resource_group" "res-3" {
  location = "eastus"
  name     = "rg-migration-test-eastus"
}
resource "azurerm_managed_disk" "res-4" {
  create_option        = "Empty"
  location             = "eastus"
  name                 = "disk-data-vm-test-01"
  resource_group_name  = "rg-migration-test-eastus"
  storage_account_type = "Premium_LRS"
  depends_on = [
    azurerm_resource_group.res-3
  ]
}
resource "azurerm_managed_disk" "res-5" {
  create_option        = "Empty"
  location             = "eastus"
  name                 = "disk-data-vm-test-02"
  resource_group_name  = "rg-migration-test-eastus"
  storage_account_type = "PremiumV2_LRS"
  zone                 = "1"
  depends_on = [
    azurerm_resource_group.res-3
  ]
}
resource "azurerm_managed_disk" "res-6" {
  create_option        = "Empty"
  location             = "eastus"
  name                 = "disk-data-vm-test-03"
  resource_group_name  = "rg-migration-test-eastus"
  storage_account_type = "Premium_LRS"
  depends_on = [
    azurerm_resource_group.res-3
  ]
}
resource "azurerm_linux_virtual_machine" "res-8" {
  admin_username        = "azureuser"
  location              = "eastus"
  name                  = "vm-test-01"
  network_interface_ids = [azurerm_network_interface.res-26.id]
  resource_group_name   = "rg-migration-test-eastus"
  secure_boot_enabled   = true
  size                  = "Standard_D16ds_v6"
  disk_controller_type  = "NVMe"
  vtpm_enabled          = true
  admin_ssh_key {
    public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCzprTjY5mmz35853u+HyLbktYbIQ24LPot+3rMaVDST9g22xatZke8rdEOGN0vM5w1z2F3PMpSHlvhz4Ka9sz9h40GSvt7eJVjfkG8Ddh3hZZyo/ooAt+Ld8MrBNATZXVK80QcGktklhY9F2qJd8DGzKTP3uiljwraVgP2rqVyscP5Ur2edQcF+BU/02z35sycDuvbejjQkWCNGqfGLIsJGOAtxFQk/EGMSBf+Usp8wAa3ox24YJGsouhc1k8vOHqUBcRWI+3iEw+RvBvjTlplurB9TuMAODKd28MZXj2SnQ2c8G/c0xqpks94+LtjIl7cf3Hjqd+ktKmOZwOxbDsJ"
    username   = "azureuser"
  }
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }
  source_image_reference {
    offer     = "ubuntu-24_04-lts"
    publisher = "Canonical"
    sku       = "server"
    version   = "24.04.202504080"
  }
}
resource "azurerm_virtual_machine_data_disk_attachment" "res-9" {
  caching            = "None"
  lun                = 0
  managed_disk_id    = azurerm_managed_disk.res-4.id
  virtual_machine_id = azurerm_linux_virtual_machine.res-8.id
}
resource "azurerm_linux_virtual_machine" "res-12" {
  admin_username        = "azureuser"
  location              = "eastus"
  name                  = "vm-test-02"
  network_interface_ids = [azurerm_network_interface.res-29.id]
  resource_group_name   = "rg-migration-test-eastus"
  secure_boot_enabled   = true
  size                  = "Standard_D8ds_v6"
  disk_controller_type  = "NVMe"
  vtpm_enabled          = true
  zone                  = "1"
  admin_ssh_key {
    public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCzprTjY5mmz35853u+HyLbktYbIQ24LPot+3rMaVDST9g22xatZke8rdEOGN0vM5w1z2F3PMpSHlvhz4Ka9sz9h40GSvt7eJVjfkG8Ddh3hZZyo/ooAt+Ld8MrBNATZXVK80QcGktklhY9F2qJd8DGzKTP3uiljwraVgP2rqVyscP5Ur2edQcF+BU/02z35sycDuvbejjQkWCNGqfGLIsJGOAtxFQk/EGMSBf+Usp8wAa3ox24YJGsouhc1k8vOHqUBcRWI+3iEw+RvBvjTlplurB9TuMAODKd28MZXj2SnQ2c8G/c0xqpks94+LtjIl7cf3Hjqd+ktKmOZwOxbDsJ"
    username   = "azureuser"
  }
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }
  source_image_reference {
    offer     = "ubuntu-24_04-lts"
    publisher = "Canonical"
    sku       = "server"
    version   = "24.04.202504080"
  }
}
resource "azurerm_virtual_machine_data_disk_attachment" "res-13" {
  caching            = "None"
  lun                = 0
  managed_disk_id    = azurerm_managed_disk.res-5.id
  virtual_machine_id = azurerm_linux_virtual_machine.res-12.id
}
resource "azurerm_linux_virtual_machine" "res-16" {
  admin_username        = "azureuser"
  location              = "eastus"
  name                  = "vm-test-03"
  network_interface_ids = [azurerm_network_interface.res-32.id]
  resource_group_name   = "rg-migration-test-eastus"
  secure_boot_enabled   = true
  size                  = "Standard_D2ds_v6"
  disk_controller_type  = "NVMe"
  vtpm_enabled          = true
  admin_ssh_key {
    public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCzprTjY5mmz35853u+HyLbktYbIQ24LPot+3rMaVDST9g22xatZke8rdEOGN0vM5w1z2F3PMpSHlvhz4Ka9sz9h40GSvt7eJVjfkG8Ddh3hZZyo/ooAt+Ld8MrBNATZXVK80QcGktklhY9F2qJd8DGzKTP3uiljwraVgP2rqVyscP5Ur2edQcF+BU/02z35sycDuvbejjQkWCNGqfGLIsJGOAtxFQk/EGMSBf+Usp8wAa3ox24YJGsouhc1k8vOHqUBcRWI+3iEw+RvBvjTlplurB9TuMAODKd28MZXj2SnQ2c8G/c0xqpks94+LtjIl7cf3Hjqd+ktKmOZwOxbDsJ"
    username   = "azureuser"
  }
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }
  source_image_reference {
    offer     = "ubuntu-24_04-lts"
    publisher = "Canonical"
    sku       = "server"
    version   = "24.04.202504080"
  }
}
resource "azurerm_virtual_machine_data_disk_attachment" "res-17" {
  caching            = "None"
  lun                = 0
  managed_disk_id    = azurerm_managed_disk.res-6.id
  virtual_machine_id = azurerm_linux_virtual_machine.res-16.id
}
resource "azurerm_lb" "res-22" {
  location            = "eastus"
  name                = "lb-source"
  resource_group_name = "rg-migration-test-eastus"
  frontend_ip_configuration {
    name = "fe"
  }
  depends_on = [
    azurerm_resource_group.res-3
  ]
}
resource "azurerm_lb_backend_address_pool" "res-23" {
  loadbalancer_id = azurerm_lb.res-22.id
  name            = "bepool"
}
resource "azurerm_lb_rule" "res-24" {
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.res-23.id]
  backend_port                   = 443
  frontend_ip_configuration_name = "fe"
  frontend_port                  = 443
  loadbalancer_id                = azurerm_lb.res-22.id
  name                           = "route_https"
  probe_id                       = azurerm_lb_probe.res-25.id
  protocol                       = "Tcp"
}
resource "azurerm_lb_probe" "res-25" {
  interval_in_seconds = 5
  loadbalancer_id     = azurerm_lb.res-22.id
  name                = "ping_api"
  port                = 9080
  protocol            = "Http"
  request_path        = "/hello"
}
resource "azurerm_network_interface" "res-26" {
  location            = "eastus"
  name                = "nic-vm-test-01"
  resource_group_name = "rg-migration-test-eastus"
  ip_configuration {
    name                          = "ipconfig1"
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.1.4"
    public_ip_address_id          = azurerm_public_ip.res-44.id
    subnet_id                     = azurerm_subnet.res-48.id
  }
  depends_on = [
    # One of azurerm_subnet.res-48,azurerm_subnet_network_security_group_association.res-49 (can't auto-resolve as their ids are identical)
  ]
}
resource "azurerm_network_interface_backend_address_pool_association" "res-27" {
  backend_address_pool_id = azurerm_lb_backend_address_pool.res-23.id
  ip_configuration_name   = "ipconfig1"
  network_interface_id    = azurerm_network_interface.res-26.id
}
resource "azurerm_network_interface_security_group_association" "res-28" {
  network_interface_id      = azurerm_network_interface.res-26.id
  network_security_group_id = azurerm_network_security_group.res-35.id
}
resource "azurerm_network_interface" "res-29" {
  location            = "eastus"
  name                = "nic-vm-test-02"
  resource_group_name = "rg-migration-test-eastus"
  ip_configuration {
    name                          = "ipconfig1"
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.1.5"
    public_ip_address_id          = azurerm_public_ip.res-45.id
    subnet_id                     = azurerm_subnet.res-48.id
  }
  depends_on = [
    # One of azurerm_subnet.res-48,azurerm_subnet_network_security_group_association.res-49 (can't auto-resolve as their ids are identical)
  ]
}
resource "azurerm_network_interface_backend_address_pool_association" "res-30" {
  backend_address_pool_id = azurerm_lb_backend_address_pool.res-23.id
  ip_configuration_name   = "ipconfig1"
  network_interface_id    = azurerm_network_interface.res-29.id
}
resource "azurerm_network_interface_security_group_association" "res-31" {
  network_interface_id      = azurerm_network_interface.res-29.id
  network_security_group_id = azurerm_network_security_group.res-35.id
}
resource "azurerm_network_interface" "res-32" {
  location            = "eastus"
  name                = "nic-vm-test-03"
  resource_group_name = "rg-migration-test-eastus"
  ip_configuration {
    name                          = "ipconfig1"
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.1.6"
    public_ip_address_id          = azurerm_public_ip.res-46.id
    subnet_id                     = azurerm_subnet.res-48.id
  }
  depends_on = [
    # One of azurerm_subnet.res-48,azurerm_subnet_network_security_group_association.res-49 (can't auto-resolve as their ids are identical)
  ]
}
resource "azurerm_network_interface_backend_address_pool_association" "res-33" {
  backend_address_pool_id = azurerm_lb_backend_address_pool.res-23.id
  ip_configuration_name   = "ipconfig1"
  network_interface_id    = azurerm_network_interface.res-32.id
}
resource "azurerm_network_interface_security_group_association" "res-34" {
  network_interface_id      = azurerm_network_interface.res-32.id
  network_security_group_id = azurerm_network_security_group.res-35.id
}
resource "azurerm_network_security_group" "res-35" {
  location            = "eastus"
  name                = "nsg-workload"
  resource_group_name = "rg-migration-test-eastus"
  depends_on = [
    azurerm_resource_group.res-3
  ]
}
resource "azurerm_network_security_rule" "res-36" {
  access                      = "Allow"
  description                 = "Allow HTTP inbound"
  destination_address_prefix  = "*"
  destination_port_range      = "80"
  direction                   = "Inbound"
  name                        = "AllowHTTP"
  network_security_group_name = "nsg-workload"
  priority                    = 1010
  protocol                    = "Tcp"
  resource_group_name         = "rg-migration-test-eastus"
  source_address_prefix       = "*"
  source_port_range           = "*"
  depends_on = [
    azurerm_network_security_group.res-35
  ]
}
resource "azurerm_public_ip" "res-43" {
  allocation_method = "Static"
  domain_name_label = "cu-lb-source-avivk8"
  ip_tags = {
    FirstPartyUsage = "/Unprivileged"
  }
  location            = "eastus"
  name                = "pip-source-lb"
  resource_group_name = "rg-migration-test-eastus"
  depends_on = [
    azurerm_resource_group.res-3
  ]
}
resource "azurerm_public_ip" "res-44" {
  allocation_method = "Static"
  domain_name_label = "controlup-sip-vm-test-01-avivk8"
  ip_tags = {
    FirstPartyUsage = "/Unprivileged"
  }
  location            = "eastus"
  name                = "vm-test-01-pip"
  resource_group_name = "rg-migration-test-eastus"
  depends_on = [
    azurerm_resource_group.res-3
  ]
}
resource "azurerm_public_ip" "res-45" {
  allocation_method = "Static"
  domain_name_label = "controlup-sip-vm-test-02-avivk8"
  ip_tags = {
    FirstPartyUsage = "/Unprivileged"
  }
  location            = "eastus"
  name                = "vm-test-02-pip"
  resource_group_name = "rg-migration-test-eastus"
  depends_on = [
    azurerm_resource_group.res-3
  ]
}
resource "azurerm_public_ip" "res-46" {
  allocation_method = "Static"
  domain_name_label = "controlup-sip-vm-test-03-avivk8"
  ip_tags = {
    FirstPartyUsage = "/Unprivileged"
  }
  location            = "eastus"
  name                = "vm-test-03-pip"
  resource_group_name = "rg-migration-test-eastus"
  depends_on = [
    azurerm_resource_group.res-3
  ]
}
resource "azurerm_virtual_network" "res-47" {
  address_space       = ["10.0.0.0/16"]
  location            = "eastus"
  name                = "vnet-source"
  resource_group_name = "rg-migration-test-eastus"
  depends_on = [
    azurerm_resource_group.res-3
  ]
}
resource "azurerm_subnet" "res-48" {
  address_prefixes                = ["10.0.1.0/24"]
  default_outbound_access_enabled = false
  name                            = "snet-workload"
  resource_group_name             = "rg-migration-test-eastus"
  virtual_network_name            = "vnet-source"
  depends_on = [
    azurerm_virtual_network.res-47
  ]
}
resource "azurerm_subnet_network_security_group_association" "res-49" {
  network_security_group_id = azurerm_network_security_group.res-35.id
  subnet_id                 = azurerm_subnet.res-48.id
}