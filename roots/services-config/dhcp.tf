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
}

module "dhcp" {
  source   = "../../modules/services/dhcp"
  for_each = local.dhcp_vms

  fabric_macs   = module.dhcp_macs.fabric_macs[each.key]
  name          = each.key
  management_ip = split("/", each.value.management_address)[0]
}
