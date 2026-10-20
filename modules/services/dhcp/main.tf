locals {
  system_commands = [
    "set system ip disable-forwarding",
    "set system host-name '${var.name}'"
  ]
}
# One combined configuration request per DHCP VM, matching the leaf module.
resource "vyoscmd_commands" "this" {
  name     = "${var.name}-dhcp"
  endpoint = "https://${var.management_ip}"
  save     = true

  commands = flatten([
    local.system_commands,
    local.interface_commands,
    local.dhcp_ha_commands,
    local.dhcp_listen_commands,
    local.dhcp_pool_commands,
  ])
}
