locals {
  router_id = cidrhost(var.fabric.settings.loopback_ipv4_prefix, var.leaf.id)
  # Preserve the old fabric convention: ID 18 becomes IPv6 suffix ::18.
  vtep_ipv6 = cidrhost(var.fabric.settings.loopback_ipv6_prefix, parseint(tostring(var.leaf.id), 16))
  vtep_mac  = format("00:13:37:00:%02x:%02x", floor(var.leaf.id / 256), var.leaf.id % 256)

  # Border inventory uses separate VPN RT fields. Other VRFs use the normal fields.
  ipv4_rt_imports = {
    for name, vrf in local.role_vrfs : name => coalesce(
      var.leaf.role == "external_l3" ? vrf.border_leaf_ipv4_rt_imports : vrf.ipv4_rt_imports,
      "${var.fabric.overlay_as}:${vrf.vni}",
    )
  }
  ipv4_rt_exports = {
    for name, vrf in local.role_vrfs : name => coalesce(
      var.leaf.role == "external_l3" ? vrf.border_leaf_ipv4_rt_exports : vrf.ipv4_rt_exports,
      "${var.fabric.overlay_as}:${vrf.vni}",
    )
  }
}
