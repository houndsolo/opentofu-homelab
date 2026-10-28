output "leaf_vms" {
  description = "One leaf VM per Proxmox node, with its identity and ordered extra NICs."
  value = {
    for name, vm in merge(module.vm, module.greatfox_vm) : name => {
      name               = vm.name
      vm_id              = vm.vm_id
      node_name          = vm.node_name
      management_address = vm.management_address
      network_devices    = vm.network_devices
    }
  }
}
