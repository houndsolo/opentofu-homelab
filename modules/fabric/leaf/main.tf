locals {
  specification = merge(var.leaf, {
    name        = var.name
    overlay_as  = var.overlay_as
    fabric_macs = var.fabric_macs
  })
}

resource "vyoscmd_commands" "interface_bindings" {
  count    = length(var.fabric_macs) > 0 ? 1 : 0
  name     = "${var.name}-interface-bindings"
  endpoint = "https://${var.leaf.management_ip}"
  commands = toset([
    for interface, mac in var.fabric_macs : "set interfaces ethernet ${interface} hw-id ${mac}"
  ])
}
