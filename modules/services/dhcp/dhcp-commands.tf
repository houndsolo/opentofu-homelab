locals {
  # Add pool commands here, eventually generated from DHCP-enabled L2VNIs.
  dhcp_ha_commands = [
    "set service dhcp-server high-availability mode 'active-passive'",
    "set service dhcp-server high-availability name 'vyos-DHCP-${var.ha.peer_slot}'",
    "set service dhcp-server high-availability remote '${cidrhost(var.dhcp_ha_subnet,var.ha.peer_slot)}'",
    "set service dhcp-server high-availability source-address '${cidrhost(var.dhcp_ha_subnet,var.ha.address_slot)}'",
    "set service dhcp-server high-availability status '${var.ha.role}'",  
  ]
  dhcp_pool_commands = [
    "set service dhcp-server shared-network-name l2vni9012 authoritative",
    "set service dhcp-server shared-network-name l2vni9012 subnet 10.12.0.0/16 lease '86400'",
    "set service dhcp-server shared-network-name l2vni9012 subnet 10.12.0.0/16 option default-router '10.12.0.5'",
    "set service dhcp-server shared-network-name l2vni9012 subnet 10.12.0.0/16 option domain-name 'lylat.space'",
    "set service dhcp-server shared-network-name l2vni9012 subnet 10.12.0.0/16 option domain-search 'lylat.space'",
    "set service dhcp-server shared-network-name l2vni9012 subnet 10.12.0.0/16 option name-server '10.8.53.1'",
    "set service dhcp-server shared-network-name l2vni9012 subnet 10.12.0.0/16 option name-server '10.8.53.2'",
    "set service dhcp-server shared-network-name l2vni9012 subnet 10.12.0.0/16 range 0 start '10.12.5.1'",
    "set service dhcp-server shared-network-name l2vni9012 subnet 10.12.0.0/16 range 0 stop '10.12.5.99'",
    "set service dhcp-server shared-network-name l2vni9012 subnet 10.12.0.0/16 subnet-id '9012'",
  ]
}
