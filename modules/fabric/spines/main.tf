locals {
  spine_as = coalesce(var.spine.as, var.fabric.settings.spine_as)
  # Loopback host numbers read the decimal ID as hex: id 11 -> ...::11.
  spine_loopback = cidrhost(var.fabric.settings.loopback_ipv6_prefix, parseint(tostring(var.spine.id), 16))
  leaf_loopbacks = {
    for name, leaf in var.leaves :
    name => cidrhost(var.fabric.settings.loopback_ipv6_prefix, parseint(tostring(leaf.id), 16))
  }
  # Spine-side port toward each leaf: ether<leaf id> unless spine_uplink overrides it.
  leaf_uplinks = {
    for name, leaf in var.leaves : name => coalesce(leaf.spine_uplink, "ether${leaf.id}")
  }
}

moved {
  from = routeros_ipv6_firewall_addr_list.BGP-LOOPBACKS
  to   = routeros_ipv6_firewall_addr_list.bgp_loopbacks
}

moved {
  from = routeros_ipv6_nd_prefix.test
  to   = routeros_ipv6_nd_prefix.leaf_uplinks
}

resource "routeros_ipv6_firewall_addr_list" "bgp_loopbacks" {
  address = local.spine_loopback
  list    = "BGP-LOOPBACKS"
}

resource "routeros_ipv6_firewall_addr_list" "fabric_loopbacks_ipv6" {
  address = var.fabric.settings.loopback_ipv6_prefix
  list    = "fabric_loopbacks_ipv6"
}

resource "routeros_routing_bfd_configuration" "bfd_to_overlay" {
  depends_on   = [routeros_ipv6_firewall_addr_list.fabric_loopbacks_ipv6]
  forbid_bfd   = false
  address_list = "fabric_loopbacks_ipv6"
}

resource "routeros_routing_bfd_configuration" "bfd_to_leaves" {
  interfaces = values(local.leaf_uplinks)

  forbid_bfd = false
}

resource "routeros_routing_bgp_instance" "main" {
  as        = local.spine_as
  name      = "default"
  router_id = "rid-spine"
}

resource "routeros_ipv6_nd_prefix" "leaf_uplinks" {
  for_each  = local.leaf_uplinks
  prefix    = "none"
  interface = each.value
}

resource "routeros_routing_bgp_template" "underlay" {
  name             = "SPINE-eBGP-v6-LL"
  as               = local.spine_as
  address_families = "ipv6"
  nexthop_choice   = "force-self"
  output {
    network = "BGP-LOOPBACKS"
  }
}

resource "routeros_routing_bgp_connection" "underlay" {
  for_each         = var.leaves
  name             = "underlay-leaf-${each.value.id}"
  as               = local.spine_as
  address_families = "ipv6"
  instance         = "default"
  use_bfd          = true
  local {
    role    = "ebgp"
    address = local.leaf_uplinks[each.key]
  }
  templates = ["SPINE-eBGP-v6-LL"]
  output {
    network = "BGP-LOOPBACKS"
  }
}

resource "routeros_routing_filter_rule" "evpn_chain" {
  chain    = "EVPN-IN"
  rule     = "set scope-target 40; accept;"
  disabled = false
}

resource "routeros_routing_bgp_template" "overlay" {
  name             = "SPINE-iBGP-EVPN"
  as               = var.fabric.settings.overlay_as
  address_families = "evpn"
  nexthop_choice   = "propagate"
  input {
    filter = "EVPN-IN"
  }
}

resource "routeros_routing_bgp_connection" "overlay" {
  for_each         = var.leaves
  name             = "overlay-leaf-${each.value.id}"
  as               = var.fabric.settings.overlay_as
  address_families = "evpn"
  instance         = "default"
  use_bfd          = true
  input {
    filter = "EVPN-IN"
  }
  local {
    role    = "ibgp-rr"
    address = local.spine_loopback
  }
  remote {
    address = local.leaf_loopbacks[each.key]
  }
  templates = ["SPINE-iBGP-EVPN"]
}

