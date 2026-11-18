# Leaf-facing ports. Each is a routed point-to-point link with only link-local addresses: the leaf finds the
# spine's link-local from RAs and peers to it (FRR `neighbor ethN interface v6only`).

resource "routeros_interface_ethernet" "leaf" {
  for_each     = local.leaves
  factory_name = each.value.port
  name         = each.value.port
  mtu          = var.port_mtu
  l2mtu        = var.port_l2mtu
  comment      = "leaf-${each.value.id}"
}

# RAs on every leaf port: the leaves learn the spine's link-local from them. The RouterOS default interval
# (3m20s-10m) can stall a booting leaf's underlay for minutes. A new leaf port without its entry never peers.
resource "routeros_ipv6_neighbor_discovery" "leaf" {
  for_each      = local.leaves
  interface     = each.value.port
  ra_interval   = "10s-30s"
  advertise_dns = false
}

# No prefix in the RAs: the links stay link-local only.
resource "routeros_ipv6_nd_prefix" "leaf" {
  for_each  = local.leaves
  interface = each.value.port
  prefix    = "none"
}

# The built-in `interface=all` ND entry stays disabled (owner's call): it sent 30-minute default routes onto
# vlan5, the bridge and mgmt. It can't be created or deleted, so the root imports it (imports.tf).
resource "routeros_ipv6_neighbor_discovery" "default_all" {
  interface     = "all"
  disabled      = true
  advertise_dns = false # as on the device; the provider would otherwise flip it to its default (true)
}

resource "routeros_routing_bfd_configuration" "leaf_ports" {
  interfaces = local.ports
  forbid_bfd = false
}

# Route the underlay (VXLAN between the leaves) in the switch chip. A singleton, imported by the root. The
# matching `l3hw-settings ipv6-hw=yes` has no provider resource and stays a hand setting.
resource "routeros_interface_ethernet_switch" "l3hw" {
  name             = var.switch_name
  l3_hw_offloading = true
}
