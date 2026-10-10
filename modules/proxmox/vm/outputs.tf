output "vm_id" {
  description = "Proxmox VM ID."
  value       = proxmox_virtual_environment_vm.this.vm_id
}

output "node_name" {
  description = "Proxmox node hosting the VM."
  value       = proxmox_virtual_environment_vm.this.node_name
}

output "name" {
  description = "VM hostname."
  value       = proxmox_virtual_environment_vm.this.name
}

output "management_address" {
  description = "Configured management IPv4 address, or null when cloud-init is disabled."
  value       = local.config.cloud_init ? var.vm.management_address : null
}

output "network_devices" {
  description = "Ordered extra NICs, excluding the management NIC."
  value       = var.vm.network_devices
}
