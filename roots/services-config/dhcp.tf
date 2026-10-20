module "dhcp_macs" {
  source = "../../modules/services/dhcp/macs"
  vms    = { for name, vm in var.vms : name => vm if vm.owner == "services-vms-dhcp" }
  dhcp_vlans = flatten([
    for l3 in var.vnis : [
      for l2 in values(l3.l2) : l2.vlan_id if l2.dhcp != null
    ]
  ])
}

locals {
  dhcp_vms = {
    for name, vm in var.vms : name => vm
    if vm.owner == "services-vms-dhcp"
  }

  # Numeric VM-ID order, independent of names or map iteration order.
  dhcp_names = [
    for entry in sort([
      for name, vm in local.dhcp_vms : format("%010d:%s", vm.vm_id, name)
    ]) : split(":", entry)[1]
  ]
  dhcp_ha_subnet = "10.6.67.0/16"

  dhcp_ha = length(local.dhcp_names) == 2 ? {
    for index, name in local.dhcp_names : name => {
      role                = index == 0 ? "primary" : "secondary"
      index        = index 
      remote_index        = 1 - index 
      address_slot        = index + 1
      peer_slot           = 2 - index # good meme
      peer_name           = local.dhcp_names[1 - index]
      local_management_ip = split("/", local.dhcp_vms[name].management_address)[0]
      peer_management_ip  = split("/", local.dhcp_vms[local.dhcp_names[1 - index]].management_address)[0]
    }
  } : {}

  dhcp_prefix_lengths = {
    for l2 in flatten([for l3 in var.vnis : [for l2 in values(l3.l2) : l2 if l2.dhcp != null]]) :
    tostring(l2.vlan_id) => l2.anycast_gw_cidr
  }

}

module "dhcp" {
  source   = "../../modules/services/dhcp"
  for_each = local.dhcp_ha

  dhcp_ha_subnet = local.dhcp_ha_subnet
  fabric_macs   = module.dhcp_macs.fabric_macs[each.key]
  name          = each.key
  management_ip = each.value.local_management_ip
  ha            = each.value
  interface_addresses = {
    for index, nic in module.dhcp_macs.network_devices[each.key] :
    "eth${index + 1}" => "10.${nic.vlan_id}.67.${each.value.address_slot}/${local.dhcp_prefix_lengths[tostring(nic.vlan_id)]}"
  }
}
