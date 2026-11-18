resource "routeros_routing_id" "fabric" {
  name      = "fabric"
  router_id = local.router_id
}

resource "routeros_ip_address" "loopback" {
  address   = "${local.router_id}/32"
  interface = "lo"
  comment   = "fabric loopback / router id"
}

resource "routeros_ipv6_address" "loopback" {
  address   = "${local.loopback_ipv6}/128"
  interface = "lo"
  advertise = false
  comment   = "fabric loopback"
}

# What the sessions advertise (bgp.tf output.network): only the spine's own loopback. The leaves' loopbacks
# are passed on as received routes.
resource "routeros_ipv6_firewall_addr_list" "loopback" {
  list    = "FABRIC-LOOPBACK"
  address = local.loopback_ipv6
}
