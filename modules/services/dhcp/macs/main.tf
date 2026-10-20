locals {
  # Sort by padded numeric VLAN, not lexicographic strings (2 comes before 12).
  vlans = [for vlan in sort([for vlan in var.dhcp_vlans : format("%02d", vlan)]) : tonumber(vlan)]

  network_devices = {
    for name, vm in var.vms : name => [
      for vlan in local.vlans : {
        bridge      = "vmbr4000"
        vlan_id     = vlan
        mac_address = format("02:00:00:67:%02d:%02d", vm.vm_id % 100, vlan)
      }
    ]
  }
}

output "network_devices" {
  description = "VM -> ordered extra NICs; management is created separately."
  value       = local.network_devices
}

output "fabric_macs" {
  description = "VM -> ethN -> MAC, using the same list order as VM creation."
  value = {
    for name, devices in local.network_devices : name => {
      for index, device in devices : "eth${index + 1}" => device.mac_address
    }
  }
}
