# ──────────────────────────── NICs ──────────────────────────────────────

resource "azurerm_network_interface" "vm" {
  for_each = local.vms

  name                = "nic-${each.key}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.workload.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface_security_group_association" "vm" {
  for_each = local.vms

  network_interface_id      = azurerm_network_interface.vm[each.key].id
  network_security_group_id = azurerm_network_security_group.this.id
}

# ──────────────────────────── LB Backend Association ───────────────────

resource "azurerm_network_interface_backend_address_pool_association" "vm" {
  for_each = local.vms

  network_interface_id    = azurerm_network_interface.vm[each.key].id
  ip_configuration_name   = "ipconfig1"
  backend_address_pool_id = azurerm_lb_backend_address_pool.this.id
}

# ──────────────────────────── VMs (Trusted Launch) ─────────────────────

resource "azurerm_linux_virtual_machine" "vm" {
  for_each = local.vms

  name                = each.key
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  size                = each.value.size
  zone                = each.value.zone
  admin_username      = var.admin_username

  network_interface_ids = [azurerm_network_interface.vm[each.key].id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(var.ssh_public_key_path)
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  secure_boot_enabled = true
  vtpm_enabled        = true

  disable_password_authentication = true
}

# ──────────────────────────── MDE Extension (Defender for Endpoint) ────

resource "azurerm_virtual_machine_extension" "mde" {
  for_each = local.vms

  name                       = "MDE.Linux"
  virtual_machine_id         = azurerm_linux_virtual_machine.vm[each.key].id
  publisher                  = "Microsoft.Azure.AzureDefenderForServers"
  type                       = "MDE.Linux"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true

  settings = jsonencode({
    autoUpdate         = true
    azureResourceId    = azurerm_linux_virtual_machine.vm[each.key].id
    forceReOnboarding  = false
    vNextEnabled       = false
  })
}

# ──────────────────────────── Data Disks ───────────────────────────────

resource "azurerm_managed_disk" "data" {
  for_each = local.vms

  name                = "disk-data-${each.key}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  storage_account_type = each.value.data_disk_sku
  create_option       = "Empty"
  disk_size_gb        = each.value.data_disk_gb
  zone                = each.value.zone
}

resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  for_each = local.vms

  managed_disk_id    = azurerm_managed_disk.data[each.key].id
  virtual_machine_id = azurerm_linux_virtual_machine.vm[each.key].id
  lun                = 0
  caching            = "None"
}
