output "leaf_vms" {
  description = "One leaf VM per Proxmox node, with its identity and ordered extra NICs."
  value = {
    for name, vm in module.vm : name => {
      name               = vm.name
      vm_id              = vm.vm_id
      node_name          = vm.node_name
      management_address = vm.management_address
      network_devices    = vm.network_devices
    }
  }
  precondition {
    condition     = length(distinct([for node in values(var.nodes.proxmox_cluster) : node.id])) == length(var.nodes.proxmox_cluster)
    error_message = "Proxmox node IDs must be unique to derive unique leaf VM IDs."
  }
}
