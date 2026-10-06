locals {
  interface_binding_commands = [
    for interface, mac in var.fabric_macs :
    "set interfaces ethernet ${interface} hw-id ${mac}"
  ]

  interface_commands = concat(
    local.interface_binding_commands,
    length(local.role_vrfs) > 0 ? flatten([
      [for spine in var.fabric.spines : [
        "set interfaces ethernet ${coalesce(spine.uplink_if, "eth${spine.id}")} description 'p2p-spine-${spine.id}'",
        "set interfaces ethernet ${coalesce(spine.uplink_if, "eth${spine.id}")} mtu '${var.fabric.settings.outer_mtu}'",
        "set service router-advert interface ${coalesce(spine.uplink_if, "eth${spine.id}")}",
      ]],
      [
        "set interfaces dummy ${var.fabric.settings.loopback_interface} address '${local.vtep_ipv6}/128'",
        "set interfaces dummy ${var.fabric.settings.loopback_interface} address '${local.router_id}/32'",
        "set interfaces dummy ${var.fabric.settings.loopback_interface} mtu '${var.fabric.settings.outer_mtu}'",
      ],
      length(local.l2vnis) > 0 ? [
        "set interfaces ethernet ${var.leaf.access_interface} description 'link to tenant VLANs'",
        "set interfaces ethernet ${var.leaf.access_interface} mtu '${var.fabric.settings.vxlan_mtu}'",
      ] : [],
    ]) : [],
  )
}
