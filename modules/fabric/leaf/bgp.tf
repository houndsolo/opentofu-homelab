locals {
  bgp_commands = local.has_vnis ? concat(
    local.bgp_base_commands,
    local.bgp_evpn_commands,
    local.bgp_neighbor_commands,
    local.bgp_spine_overlay_commands,
    local.bgp_spine_underlay_commands,
    local.bgp_spine_underlay_evpn_commands,
  ) : []

  # This leaf's own AS (the underlay AS every leaf already shows the spines via local-as).
  leaf_as = var.fabric.settings.leaf_underlay_as_base + var.leaf.id
  # EXPERIMENT (fabric.settings.leaf_own_as_ids, "option B"): the leaf's BGP instances really run as leaf_as.
  own_as        = contains(var.fabric.settings.leaf_own_as_ids, var.leaf.id)
  bgp_system_as = local.own_as ? local.leaf_as : var.fabric.settings.overlay_as

  bgp_base_commands = [
    "set protocols bgp system-as ${local.bgp_system_as}",
    "set protocols bgp parameters router-id ${local.router_id}",
    "set protocols bgp parameters log-neighbor-changes",
    "set protocols bgp address-family ipv6-unicast network ${local.vtep_ipv6}/128",
    "set protocols bgp address-family l2vpn-evpn advertise-all-vni",
    "set protocols bgp address-family l2vpn-evpn flooding head-end-replication",
    "set protocols bgp parameters bestpath as-path multipath-relax",
    "set protocols bgp parameters fast-convergence",
  ]
  # Route targets are explicit <overlay_as>:<vni> on every L2VNI: the value FRR auto-derived while every leaf
  # ran as overlay_as, now independent of the leaf's own AS. (L3VNI RTs are explicit in vnis.auto.tfvars.)
  bgp_evpn_commands = flatten([
    for vni_id, l2vni in merge(local.l2vnis, local.role_l2only_vnis) : [
      "set protocols bgp address-family l2vpn-evpn vni ${vni_id} rd '${local.router_id}:${vni_id}'",
      "set protocols bgp address-family l2vpn-evpn vni ${vni_id} route-target export '${var.fabric.settings.overlay_as}:${vni_id}'",
      "set protocols bgp address-family l2vpn-evpn vni ${vni_id} route-target import '${var.fabric.settings.overlay_as}:${vni_id}'",
    ]
  ])

  # EXPERIMENT (fabric.settings.evpn_on_underlay): ids of the spines whose underlay session to this leaf also
  # carries EVPN. This leaf has no loopback session to them; its link neighbor joins spine_underlay_evpn.
  # Every spine's AS (its own `as`, else settings.spine_as), sorted, as numbers.
  spine_as_numbers = sort(distinct([
    for spine in var.fabric.spines : tostring(coalesce(spine.as, var.fabric.settings.spine_as))
  ]))
  evpn_on_underlay_spine_ids = (
    var.fabric.settings.evpn_on_underlay != null && contains(try(var.fabric.settings.evpn_on_underlay.leaf_ids, []), var.leaf.id)
    ? var.fabric.settings.evpn_on_underlay.spine_ids : []
  )
  # Spines this leaf peers with: all of them, except that an own-AS test leaf only talks to its evpn_on_underlay
  # spines (it can't run iBGP in overlay_as with the others); interface.tf disables its links to the rest.
  peer_spines = {
    for name, spine in var.fabric.spines : name => spine
    if !local.own_as || contains(local.evpn_on_underlay_spine_ids, spine.id)
  }
  overlay_spines = { for name, spine in local.peer_spines : name => spine if !contains(local.evpn_on_underlay_spine_ids, spine.id) }

  bgp_neighbor_commands = flatten([
    for name, spine in local.peer_spines : contains(local.evpn_on_underlay_spine_ids, spine.id) ? [
      "set protocols bgp neighbor ${coalesce(spine.uplink_interface, "eth${spine.id}")} interface v6only peer-group 'spine_underlay_evpn'",
      ] : [
      "set protocols bgp neighbor ${cidrhost(var.fabric.settings.loopback_ipv6_prefix, parseint(tostring(spine.id), 16))} peer-group 'spine_overlay'",
      "set protocols bgp neighbor ${coalesce(spine.uplink_interface, "eth${spine.id}")} interface v6only peer-group 'spine_underlay'",
    ]
  ])

  bgp_spine_overlay_commands = length(local.overlay_spines) == 0 ? [] : [
    "set protocols bgp peer-group spine_overlay address-family l2vpn-evpn route-map export 'RM-EVPN-SPINE-EXPORT'",
    "set protocols bgp peer-group spine_overlay address-family l2vpn-evpn soft-reconfiguration inbound",
    "set protocols bgp peer-group spine_overlay bfd",
    "set protocols bgp peer-group spine_overlay remote-as 'internal'",
    "set protocols bgp peer-group spine_overlay update-source '${var.fabric.settings.loopback_interface}'",
  ]
  # The spines always see leaf_as: through local-as while the instance runs overlay_as, natively on an own-AS
  # leaf (VyOS refuses a local-as equal to system-as).
  bgp_spine_underlay_base = concat(
    [
      "set protocols bgp peer-group spine_underlay address-family ipv6-unicast route-map export 'local_as_rm'",
      "set protocols bgp peer-group spine_underlay address-family ipv6-unicast soft-reconfiguration inbound",
      "set protocols bgp peer-group spine_underlay bfd",
      "set protocols bgp peer-group spine_underlay capability extended-nexthop",
    ],
    local.own_as ? [] : ["set protocols bgp peer-group spine_underlay local-as ${local.leaf_as} no-prepend replace-as"],
    ["set protocols bgp peer-group spine_underlay remote-as 'external'"],
  )
  bgp_spine_underlay_commands = length(local.overlay_spines) == 0 ? [] : local.bgp_spine_underlay_base
  # EXPERIMENT: spine_underlay plus the EVPN address family on the same unnumbered eBGP session.
  bgp_spine_underlay_evpn_commands = length(local.evpn_on_underlay_spine_ids) == 0 ? [] : concat(
    [for c in local.bgp_spine_underlay_base : replace(c, "peer-group spine_underlay ", "peer-group spine_underlay_evpn ")],
    [
      "set protocols bgp peer-group spine_underlay_evpn address-family l2vpn-evpn route-map export 'RM-EVPN-SPINE-EXPORT'",
      "set protocols bgp peer-group spine_underlay_evpn address-family l2vpn-evpn soft-reconfiguration inbound",
    ],
  )
}
