locals {
  interface_binding_commands = [
    for interface, mac in var.fabric_macs :
    "set interfaces ethernet ${interface} hw-id ${mac}"
  ]

  interface_commands = concat(
    local.interface_binding_commands,
    # Same gate as BGP and VXLAN (vnis.tf has_vnis): a leaf with only standalone L2VNIs needs the
    # loopback, the spine links and the access port too.
    local.has_vnis ? flatten([
      [for spine in var.fabric.spines : [
        "set interfaces ethernet ${coalesce(spine.uplink_interface, "eth${spine.id}")} description 'p2p-spine-${spine.id}'",
        "set interfaces ethernet ${coalesce(spine.uplink_interface, "eth${spine.id}")} mtu '${var.fabric.settings.outer_mtu}'",
      ]],
      [
        "set interfaces dummy ${var.fabric.settings.loopback_interface} address '${local.vtep_ipv6}/128'",
        "set interfaces dummy ${var.fabric.settings.loopback_interface} address '${local.router_id}/32'",
        "set interfaces dummy ${var.fabric.settings.loopback_interface} description 'loopback'",
        "set interfaces dummy ${var.fabric.settings.loopback_interface} mtu '${var.fabric.settings.outer_mtu}'",
      ],
      length(local.l2vnis) + length(local.role_l2only_vnis) > 0 ? [
        "set interfaces ethernet ${var.leaf.access_interface} description 'link to tenant VLANs'",
        "set interfaces ethernet ${var.leaf.access_interface} mtu '${var.fabric.settings.vxlan_mtu}'",
      ] : [],
    ]) : [],
  )
}
