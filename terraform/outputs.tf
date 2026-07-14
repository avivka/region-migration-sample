output "resource_group_name" {
  description = "Name of the resource group"
  value       = azurerm_resource_group.this.name
}

output "vm_ids" {
  description = "Map of VM name to VM ID"
  value       = { for k, vm in azurerm_linux_virtual_machine.vm : k => vm.id }
}

output "vm_private_ips" {
  description = "Map of VM name to private IP address"
  value       = { for k, nic in azurerm_network_interface.vm : k => nic.private_ip_address }
}

output "lb_public_ip" {
  description = "Public IP address of the load balancer"
  value       = azurerm_public_ip.lb.ip_address
}

output "vm_security_profiles" {
  description = "Security profile for each VM"
  value = {
    for k, vm in azurerm_linux_virtual_machine.vm : k => {
      secure_boot = vm.secure_boot_enabled
      vtpm        = vm.vtpm_enabled
    }
  }
}
