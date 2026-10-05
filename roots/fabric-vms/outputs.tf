output "leaf_vms" {
  description = "Managed leaf VM identities and ordered NIC layout."
  value = {
    for name, vm in module.vm : name => {
      name               = local.leaf_vms[name].name
      vm_id              = vm.vm_id
      node_name          = vm.node_name
      management_address = local.leaf_vms[name].management_address
      network_devices    = local.leaf_vms[name].network_devices
    }
  }
}
