locals {
  dhcp_vms = {
    for name, vm in var.vms : name => vm
    if vm.owner == "services-vms-dhcp"
  }
}

module "dhcp" {
  source   = "../../modules/services/dhcp"
  for_each = local.dhcp_vms

  name          = each.key
  management_ip = split("/", each.value.management_address)[0]
}
