locals {
  management_ip = cidrhost(
    var.fabric.settings.management_prefix,
    var.leaf.id,
  )
}

resource "vyoscmd_commands" "this" {
  name     = "${var.name}-system"
  endpoint = "https://${local.management_ip}"
  save     = false

  commands = flatten([
    local.bgp_commands,
    local.vxlan_commands,
    local.vrf_commands,
    local.interface_commands,
    local.policy_commands,
    local.system_commands,
    local.monitoring_commands,
    local.syslog_commands,
    local.external_commands,
  ])

  lifecycle {
    precondition {
      condition = (
        length(setintersection(
          toset([for l2 in values(var.l2vnis) : l2.vni]),
          toset(concat([for l3 in var.vnis : l3.vni], flatten([for l3 in var.vnis : [for l2 in values(l3.l2) : l2.vni]]))),
        )) == 0 &&
        length(setintersection(
          toset([for l2 in values(var.l2vnis) : l2.vlan_id]),
          toset(concat([for l3 in var.vnis : l3.vlan_id], flatten([for l3 in var.vnis : [for l2 in values(l3.l2) : l2.vlan_id]]))),
        )) == 0
      )
      error_message = "Standalone L2VNIs (var.l2vnis) must not reuse a VNI or VLAN ID from var.vnis."
    }
  }
}
