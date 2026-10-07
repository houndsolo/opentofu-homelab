resource "routeros_ipv6_firewall_addr_list" "BGP-LOOPBACKS" {
  address = cidrhost(var.fabric.settings.ipv6_fabric_loopback_prefix, parseint(tostring(var.spine.id), 16))
  list    = "BGP-LOOPBACKS"
}

resource "routeros_ipv6_firewall_addr_list" "fabric_loopbacks_ipv6" {
  address = var.fabric.settings.ipv6_fabric_loopback_prefix
  list    = "fabric_loopbacks_ipv6"
}

resource "routeros_routing_bfd_configuration" "bfd_to_overlay" {
  depends_on   = [routeros_ipv6_firewall_addr_list.fabric_loopbacks_ipv6]
  forbid_bfd   = false
  address_list = "fabric_loopbacks_ipv6"
}

resource "routeros_routing_bfd_configuration" "bfd_to_leaves" {
  interfaces = [
    for leaf in values(local.all_leaves) :
    leaf.spine_uplink == null
    ? "ether${leaf.id}"
    : leaf.spine_uplink
  ]

  forbid_bfd = false
}

resource "routeros_routing_bgp_instance" "main" {
  as        = coalesce(var.spine.as, var.fabric.settings.spine_as)
  name      = "default"
  router_id = "rid-spine"
}

resource "routeros_ipv6_nd_prefix" "test" {
  for_each  = local.all_leaves
  prefix    = "none"
  interface = each.value.spine_uplink == null ? "ether${each.value.id}" : each.value.spine_uplink
}

resource "routeros_routing_bgp_template" "underlay" {
  name             = "SPINE-eBGP-v6-LL"
  as               = coalesce(var.spine.as, var.fabric.settings.spine_as)
  address_families = "ipv6"
  nexthop_choice   = "force-self"
  output {
    network = "BGP-LOOPBACKS"
  }
}

resource "routeros_routing_bgp_connection" "underlay" {
  for_each         = local.all_leaves
  name             = "underlay-leaf-${each.value.id}"
  as               = coalesce(var.spine.as, var.fabric.settings.spine_as)
  address_families = "ipv6"
  instance         = "default"
  use_bfd          = true
  local {
    role    = "ebgp"
    address = each.value.spine_uplink == null ? "ether${each.value.id}" : each.value.spine_uplink
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
  as               = var.fabric.settings.bgp_system_as
  address_families = "evpn"
  nexthop_choice   = "propagate"
  input {
    filter = "EVPN-IN"
  }
}

resource "routeros_routing_bgp_connection" "overlay" {
  for_each         = local.all_leaves
  name             = "overlay-leaf-${each.value.id}"
  as               = var.fabric.settings.bgp_system_as
  address_families = "evpn"
  instance         = "default"
  use_bfd          = true
  input {
    filter = "EVPN-IN"
  }
  local {
    role    = "ibgp-rr"
    address = cidrhost(var.fabric.settings.ipv6_fabric_loopback_prefix, parseint(tostring(var.spine.id), 16))
  }
  remote {
    address = cidrhost(var.fabric.settings.ipv6_fabric_loopback_prefix, parseint(tostring(each.value.id), 16))
  }
  templates = ["SPINE-iBGP-EVPN"]
}

