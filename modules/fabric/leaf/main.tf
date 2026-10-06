locals {
  management_ip = cidrhost(
    var.fabric.settings.vyos_mgmt_prefix,
    var.leaf.id,
  )
}

resource "vyoscmd_commands" "this" {
  name     = "${var.name}-system"
  endpoint = "https://${local.management_ip}"
  save     = false

  commands = flatten([
    #local.bgp_commands,
    #local.vxlan_commands,
    #local.vrf_commands,
    #local.interface_commands,
    #local.policy_commands,
    local.system_commands,
  ])
}
