locals {
  # HA peer configuration; pool generation is in dhcp-pools.tf.
  dhcp_ha_commands = [
    "set service dhcp-server high-availability mode 'active-passive'",
    "set service dhcp-server high-availability name 'vyos-DHCP-${var.ha.peer_slot}'",
    "set service dhcp-server high-availability remote '${cidrhost(var.dhcp_ha_subnet, var.ha.peer_slot)}'",
    "set service dhcp-server high-availability source-address '${cidrhost(var.dhcp_ha_subnet, var.ha.address_slot)}'",
    "set service dhcp-server high-availability status '${var.ha.role}'",
  ]
}
