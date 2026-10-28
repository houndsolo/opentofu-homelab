locals {
  dhcp_vlans = flatten([
    for l3 in var.vnis : [for l2 in values(l3.l2) : l2.vlan_id if l2.dhcp != null]
  ])
  # Sort by padded numeric VLAN, not lexicographic strings (2 comes before 12).
  vlans = [for vlan in sort([for vlan in local.dhcp_vlans : format("%02d", vlan)]) : tonumber(vlan)]

  network_devices = {
    for name, vm in var.vms : name => [
      for vlan in local.vlans : {
        bridge      = var.bridge
        vlan_id     = vlan
        mac_address = format("02:00:00:67:%02d:%02d", vm.vm_id % 100, vlan)
      }
    ]
  }
}

output "network_devices" {
  description = "VM -> ordered extra NICs; management is created separately."
  value       = local.network_devices
  precondition {
    condition = alltrue([
      for vlan in local.dhcp_vlans : vlan >= 1 && vlan <= 99 && vlan == floor(vlan)
    ]) && length(distinct(local.dhcp_vlans)) == length(local.dhcp_vlans)
    error_message = "DHCP-enabled VLAN IDs must be unique integers in 1..99 for the 67:peer:VLAN MAC format."
  }
}

output "interface_macs" {
  description = "VM -> ethN -> MAC, using the same list order as VM creation."
  value = {
    for name, devices in local.network_devices : name => {
      for index, device in devices : "eth${index + 1}" => device.mac_address
    }
  }
}
