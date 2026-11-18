# One eBGP session per leaf on its port (BGP unnumbered over the link-locals), carrying both address families:
#   ipv6  the VTEP loopbacks. A route passed from leaf A to leaf B gets the spine's own link-local as next hop:
#         `propagate` drops A's link-local because it belongs to another port and falls back to the local
#         address (RouterOS "Nexthop Selection").
#   evpn  type-2/3/5 routes. `propagate` keeps the originating VTEP loopback as next hop, so VXLAN goes leaf to
#         leaf; the spine never decapsulates.
# RouterOS has no per-address-family nexthop-choice; propagate happens to be right for both here.

resource "routeros_routing_bgp_instance" "fabric" {
  name      = "fabric"
  as        = local.spine_as
  router_id = routeros_routing_id.fabric.name
}

# The EVPN next hop (a leaf VTEP loopback) is itself a BGP route with scope 40, above an eBGP route's default
# target scope (10), so without this every EVPN route stays unreachable and is never passed on. Only the EVPN
# routes: raising the target scope of the ipv6 loopback routes too left everything unreachable (tested).
resource "routeros_routing_filter_rule" "leaf_in" {
  chain    = "LEAF-IN"
  rule     = "if (afi evpn) { set scope-target 40; } accept;"
  disabled = false
}

resource "routeros_routing_bgp_template" "leaf" {
  name             = "LEAF"
  as               = local.spine_as
  address_families = "ipv6,evpn"
  nexthop_choice   = "propagate"
  use_bfd          = true
  keepalive_time   = var.keepalive_time
  hold_time        = var.hold_time
  input {
    filter = routeros_routing_filter_rule.leaf_in.chain
  }
  output {
    network = routeros_ipv6_firewall_addr_list.loopback.list
  }
}

# Every setting is repeated on the connection: a connection's own value wins over the template, and RouterOS
# shows `default` for anything a connection doesn't set, so template-only changes are easy to miss.
resource "routeros_routing_bgp_connection" "leaf" {
  for_each         = local.leaves
  name             = "leaf-${each.value.id}"
  instance         = routeros_routing_bgp_instance.fabric.name
  templates        = [routeros_routing_bgp_template.leaf.name]
  as               = local.spine_as
  address_families = "ipv6,evpn"
  nexthop_choice   = "propagate"
  use_bfd          = true
  keepalive_time   = var.keepalive_time
  hold_time        = var.hold_time
  input {
    filter = routeros_routing_filter_rule.leaf_in.chain
  }
  output {
    network = routeros_ipv6_firewall_addr_list.loopback.list
  }
  local {
    role    = "ebgp"
    address = routeros_interface_ethernet.leaf[each.key].name
  }
  remote {
    as = each.value.as
  }
  depends_on = [routeros_ipv6_neighbor_discovery.leaf, routeros_routing_bfd_configuration.leaf_ports]
}
