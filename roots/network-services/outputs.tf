output "vms" {
  description = "Created service VM identities and management addresses."
  value = {
    for name, vm in merge(module.dhcp, module.dns) : name => {
      vm_id              = vm.vm_id
      node               = vm.node_name
      management_address = vm.management_address
    }
  }
  precondition {
    condition     = contains(keys(var.nodes.proxmox_cluster), var.debian_image.node) && contains(keys(var.nodes.proxmox_cluster), var.network_services.dns_bootstrap.node)
    error_message = "Image and snippet upload nodes must exist in nodes.proxmox_cluster."
  }
  precondition {
    condition = alltrue([
      for vm in concat(values(var.network_services.dhcp), values(var.network_services.dns)) : contains(keys(var.nodes.proxmox_cluster), vm.node)
    ])
    error_message = "Service VM nodes must exist in nodes.proxmox_cluster."
  }
}

output "dhcp_interfaces" {
  description = "Stable VNI/VLAN/interface/MAC layout for later DHCP configuration."
  value = {
    for name, vm in module.dhcp : name => {
      for index, vni in sort(keys(local.dhcp_segments)) : vni => {
        interface   = "eth${index + 1}"
        bridge      = vm.network_devices[index].bridge
        vlan_id     = vm.network_devices[index].vlan_id
        mac_address = vm.network_devices[index].mac_address
      }
    }
  }
}
