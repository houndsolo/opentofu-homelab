locals {
  bgp_commands = local.has_vnis ? concat(
    local.bgp_base_commands,
    local.bgp_evpn_commands,
    local.bgp_spine_commands,
  ) : []

  # This leaf's AS, in the default and in every VRF BGP instance (vrf.tf). The spines use the same rule.
  leaf_as = var.fabric.settings.underlay_as_base + var.leaf.id
  # Every spine's AS, sorted, as strings (policy.tf: AS-FROM-SPINES).
  spine_as_numbers = sort(distinct([
    for spine in var.fabric.spines : tostring(var.fabric.settings.underlay_as_base + spine.id)
  ]))
  # Leaf-side port of each spine link: eth<spine id> unless the spine sets uplink_interface.
  spine_ports = {
    for name, spine in var.fabric.spines : name => coalesce(spine.uplink_interface, "eth${spine.id}")
  }

  bgp_base_commands = [
    "set protocols bgp system-as ${local.leaf_as}",
    "set protocols bgp parameters router-id ${local.router_id}",
    "set protocols bgp parameters log-neighbor-changes",
    "set protocols bgp address-family ipv6-unicast network ${local.vtep_ipv6}/128",
    "set protocols bgp address-family l2vpn-evpn advertise-all-vni",
    "set protocols bgp address-family l2vpn-evpn flooding head-end-replication",
    # ECMP across the spines: their paths differ only in the spine's AS.
    "set protocols bgp parameters bestpath as-path multipath-relax",
    "set protocols bgp parameters fast-convergence",
  ]
  # Route targets are explicit <overlay_as>:<vni> on every L2VNI: FRR would otherwise derive them from
  # the leaf's own AS, and no two leaves would import each other's routes. (L3VNI RTs are explicit in
  # vnis.auto.tfvars.)
  bgp_evpn_commands = flatten([
    for vni_id, l2vni in merge(local.l2vnis, local.role_l2only_vnis) : [
      "set protocols bgp address-family l2vpn-evpn vni ${vni_id} rd '${local.router_id}:${vni_id}'",
      "set protocols bgp address-family l2vpn-evpn vni ${vni_id} route-target export '${var.fabric.settings.overlay_as}:${vni_id}'",
      "set protocols bgp address-family l2vpn-evpn vni ${vni_id} route-target import '${var.fabric.settings.overlay_as}:${vni_id}'",
    ]
  ])

  # One unnumbered eBGP session per spine link, carrying the underlay (ipv6-unicast: the VTEP loopbacks) and
  # EVPN. local_as_rm keeps the leaf from being underlay transit; RM-EVPN-SPINE-EXPORT is in policy.tf.
  bgp_spine_commands = concat(
    [
      for port in local.spine_ports :
      "set protocols bgp neighbor ${port} interface v6only peer-group 'spine_underlay_evpn'"
    ],
    [
      "set protocols bgp peer-group spine_underlay_evpn address-family ipv6-unicast route-map export 'local_as_rm'",
      "set protocols bgp peer-group spine_underlay_evpn address-family ipv6-unicast soft-reconfiguration inbound",
      "set protocols bgp peer-group spine_underlay_evpn bfd",
      "set protocols bgp peer-group spine_underlay_evpn capability extended-nexthop",
      "set protocols bgp peer-group spine_underlay_evpn remote-as 'external'",
      "set protocols bgp peer-group spine_underlay_evpn address-family l2vpn-evpn route-map export 'RM-EVPN-SPINE-EXPORT'",
      "set protocols bgp peer-group spine_underlay_evpn address-family l2vpn-evpn soft-reconfiguration inbound",
    ],
  )
}
