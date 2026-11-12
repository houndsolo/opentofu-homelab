module "dhcp_macs" {
  source = "../../modules/services/dhcp/macs"
  vms    = local.dhcp_vms
  vnis   = var.vnis
  # Kea HA NIC on its own L2VNI, after the DHCP data NICs (same input as services-vms).
  ha_vlan_id = var.l2vnis["ha_dhcp"].vlan_id
}

locals {
  dhcp_vms = {
    for name, vm in var.vms : name => vm
    if vm.owner == "services-vms" && vm.role == "dhcp"
  }

  # Numeric VM-ID order, independent of names or map iteration order.
  dhcp_names = [
    for entry in sort([
      for name, vm in local.dhcp_vms : format("%010d:%s", vm.vm_id, name)
    ]) : split(":", entry)[1]
  ]

  dhcp_ha = length(local.dhcp_names) == 2 ? {
    for index, name in local.dhcp_names : name => {
      role                = index == 0 ? "primary" : "secondary"
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

  ha_prefix            = var.l2vnis["ha_dhcp"].prefix
  vnis                 = var.vnis
  # Only the DNS VIP (DT-051): keepalived moves it to the healthy DNS node, and vyoscmd sorts multi-value
  # nodes as text, so a list with the node addresses would put .1/.2 ahead of the VIP. Without a VIP, fall
  # back to the node addresses.
  default_name_servers = local.dns_vip != null ? [local.dns_vip] : values(local.dns_addresses)
  interface_macs       = module.dhcp_macs.interface_macs[each.key]
  name                 = each.key
  management_ip        = each.value.local_management_ip
  prometheus_exporters = var.dhcp_prometheus_exporters
  syslog               = var.dhcp_syslog
  ha                   = each.value
  ha_interface         = module.dhcp_macs.ha_interfaces[each.key]
  interface_addresses = merge(
    {
      for index, nic in module.dhcp_macs.data_network_devices[each.key] :
      "eth${index + 1}" => "10.${nic.vlan_id}.67.${each.value.address_slot}/${local.dhcp_prefix_lengths[tostring(nic.vlan_id)]}"
    },
    # Kea HA peering: host .1 / .2 of l2vnis.ha_dhcp on the last NIC.
    {
      (module.dhcp_macs.ha_interfaces[each.key]) = "${cidrhost(var.l2vnis["ha_dhcp"].prefix, each.value.address_slot)}/${split("/", var.l2vnis["ha_dhcp"].prefix)[1]}"
    },
  )
}
