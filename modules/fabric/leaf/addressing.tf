locals {
  router_id = cidrhost(var.fabric.settings.loopback_ipv4_prefix, var.leaf.id)
  # This mess converts the Decimal ID into the hex value that would read back the Decimal.
  # ex) id=11, in hex/ipv6 this would be 'b'
  # the following converts it to decimal 17, which is hex 11
  vtep_ipv6 = cidrhost(var.fabric.settings.loopback_ipv6_prefix, parseint(tostring(var.leaf.id), 16))
  vtep_mac = format(
    "00:13:37:00:%02d:%02d",
    floor(var.leaf.id / 100),
    var.leaf.id % 100,
  )
}
