locals {
  # Example only: complete peer/local identity and other required HA settings
  # for your VyOS version before applying this module.
  # Pair identity is available as var.ha.role, var.ha.peer_name,
  # var.ha.local_management_ip and var.ha.peer_management_ip.
  dhcp_ha_commands = [
    "set service dhcp-server high-availability mode active-active",
  ]
}
