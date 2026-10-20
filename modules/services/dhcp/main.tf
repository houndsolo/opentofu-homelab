# One combined configuration request per DHCP VM, matching the leaf module.
resource "vyoscmd_commands" "this" {
  name     = "${var.name}-dhcp"
  endpoint = "https://${var.management_ip}"
  save     = true

  commands = flatten([
    local.interface_commands,
    local.dhcp_ha_commands,
    local.dhcp_pool_commands,
  ])
}
