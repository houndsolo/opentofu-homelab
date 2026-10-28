locals {
  router_id = cidrhost(var.fabric.settings.loopback_ipv4_prefix, var.leaf.id)
  # Loopback host numbers read the decimal ID as hex: id 11 -> ...::11.
  vtep_ipv6 = cidrhost(var.fabric.settings.loopback_ipv6_prefix, parseint(tostring(var.leaf.id), 16))
  vtep_mac = format(
    "00:13:37:00:%02d:%02d",
    floor(var.leaf.id / 100),
    var.leaf.id % 100,
  )
}
