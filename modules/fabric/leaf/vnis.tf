locals {
  #
  # L3VNIs / VRFs this node is allowed to use.
  #
  role_vrfs = {
    for vrf in var.vnis :
    vrf.vrf => vrf
    if contains(vrf.roles, var.leaf.role)
  }

  #
  # Flatten all L2VNIs from the permitted VRFs.
  #
  role_l2vnis_list = flatten([
    for vrf in local.role_vrfs : [
      for l2vni in vrf.l2 : merge(l2vni, { vrf = vrf.vrf })
    ]
  ])

  #
  # Convert to a map keyed by L2VNI.
  #
  l2vnis = {
    for l2vni in local.role_l2vnis_list :
    l2vni.vni => l2vni
  }

  # The L2VNIs with an IPv6 anycast gateway, and the VRFs that have at least one.
  ipv6_l2vnis = { for key, l2vni in local.l2vnis : key => l2vni if l2vni.anycast_gw_ipv6 != null }
  ipv6_vrfs   = toset([for l2vni in local.ipv6_l2vnis : l2vni.vrf])

  #
  # Standalone L2VNIs (no VRF/SVI/gateway) for this node's role, keyed by VNI. The standalone
  # Proxmox host's leaf only gets the ones marked on_standalone (none of the HA segments).
  #
  role_l2only_vnis = {
    for name, l2 in var.l2vnis :
    tostring(l2.vni) => merge(l2, { name = name })
    if contains(l2.roles, var.leaf.role) && (!var.leaf.standalone || l2.on_standalone)
  }

  # Anything to put on the VXLAN fabric at all.
  has_vnis = length(local.role_vrfs) + length(local.role_l2only_vnis) > 0

  # Key both maps by VNI to avoid collisions with VRF names.
  all_vnis = merge(
    local.l2vnis,
    { for vrf in local.role_vrfs : tostring(vrf.vni) => vrf },
  )
}
