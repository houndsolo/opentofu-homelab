output "vms" {
  description = "Service VM identity and configured management address."
  value = {
    for name, vm in module.vm : name => {
      vm_id              = vm.vm_id
      node_name          = vm.node_name
      name               = vm.name
      management_address = vm.management_address
    }
  }
}
