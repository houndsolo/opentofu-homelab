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
  value       = var.vm_config.cloud_init ? proxmox_virtual_environment_vm.this.initialization[0].ip_config[0].ipv4[0].address : null
}

output "network_devices" {
  description = "Ordered extra NICs, excluding the management NIC."
  value       = var.vm.network_devices
}

output "import_image" {
  description = "Boot disk source image ID."
  value       = proxmox_virtual_environment_vm.this.disk[0].import_from
}

output "ip_configs" {
  description = "Ordered cloud-init IPv4 settings, when enabled."
  value = flatten([
    for init in proxmox_virtual_environment_vm.this.initialization : [
      for ip in init.ip_config : { address = ip.ipv4[0].address, gateway = ip.ipv4[0].gateway }
    ]
  ])
}
