locals {
  # No `hw-id` lines: current VyOS rolling (2026-11 builds) dropped the node and names ethN by slot at boot
  # (vyos.dev T3871), and the Proxmox NIC order is fixed (net0..net3).
  # Same gate as BGP and VXLAN (vnis.tf has_vnis): a leaf with only standalone L2VNIs needs the
  # loopback, the spine links and the access port too.
  interface_commands = local.has_vnis ? flatten([
    [for name, spine in var.fabric.spines : [
      "set interfaces ethernet ${local.spine_ports[name]} description 'p2p-spine-${spine.id}'",
      "set interfaces ethernet ${local.spine_ports[name]} mtu '${var.fabric.settings.outer_mtu}'",
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
  ]) : []
}
