locals {
  # Example only: complete peer/local identity and other required HA settings
  # for your VyOS version before applying this module.
  dhcp_ha_commands = [
    "set service dhcp-server high-availability mode active-active",
  ]
}
