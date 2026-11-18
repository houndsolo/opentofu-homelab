# One RouterOS spine of the EVPN/VXLAN fabric: the spine's loopback and router id, the leaf-facing ports and
# ONE eBGP session per leaf that carries both the underlay (the leaves' VTEP loopbacks, ipv6) and EVPN
# ("option C", branch ebgp-evpn). The spine is a plain eBGP route forwarder: it keeps the originating VTEP as
# the EVPN next hop (nexthop-choice=propagate) and never takes part in VXLAN.
#
#   loopback.tf  router id, lo addresses, the address list the sessions advertise
#   ports.tf     leaf ports: MTU, IPv6 RAs (BGP unnumbered), BFD, L3 hardware offload
#   bgp.tf       instance, input chain, template, one connection per leaf
#   system.tf    NTP client, in-memory log;  syslog.tf  remote syslog
#
# Not here on purpose: management/OOB (bridge, vlan5, ether21/22/24, addresses, default route) and the Proxmox
# corosync ports (ether1-7). RouterOS's `/interface ethernet switch l3hw-settings ipv6-hw=yes` has no provider
# resource; it is set by hand (see the root README).
locals {
  # Underlay AS = underlay_as_base + id, for spines (m326-1 701) and leaves (leaf-17 717) alike.
  spine_as = var.fabric.settings.underlay_as_base + var.spine.id

  # Loopbacks: IPv4 = router id, IPv6 = advertised to the leaves. Host numbers read the decimal ID as hex
  # (id 11 -> ...::11), the same expression the leaf module uses.
  router_id     = cidrhost(var.fabric.settings.loopback_ipv4_prefix, var.spine.id)
  loopback_ipv6 = cidrhost(var.fabric.settings.loopback_ipv6_prefix, parseint(tostring(var.spine.id), 16))

  # One entry per leaf: the spine port it hangs off (ether<leaf id> unless spine_uplink overrides it) and the
  # AS it presents (underlay_as_base + id, via local-as or its own system-as).
  leaves = {
    for name, leaf in var.leaves : name => {
      id   = leaf.id
      port = coalesce(leaf.spine_uplink, "ether${leaf.id}")
      as   = var.fabric.settings.underlay_as_base + leaf.id
    }
  }
  ports = sort([for leaf in local.leaves : leaf.port])
}
