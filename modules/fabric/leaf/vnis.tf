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
    for vrf_name, vrf in local.role_vrfs : [
      for vlan_key, l2vni in try(vrf.l2, {}) : merge(
        l2vni,
        {
          vrf       = vrf.vrf
          vrf_table = vrf.vrf_table
          l3vni     = vrf.vni
          roles     = vrf.roles
        }
      )
    ]
  ])

  #
  # Convert to a map keyed by L2VNI.
  #
  l2vnis = {
    for l2vni in local.role_l2vnis_list :
    l2vni.vni => l2vni
  }
  #
  # Standalone L2VNIs (no VRF/SVI/gateway) for this node's role, keyed by VNI.
  #
  role_l2only_vnis = {
    for name, l2 in var.l2vnis :
    tostring(l2.vni) => merge(l2, { name = name })
    if contains(l2.roles, var.leaf.role)
  }

  # Anything to put on the VXLAN fabric at all.
  has_vnis = length(local.role_vrfs) + length(local.role_l2only_vnis) > 0

  # Key both maps by VNI to avoid collisions with VRF names.
  all_vnis = merge(
    local.l2vnis,
    { for vrf in local.role_vrfs : tostring(vrf.vni) => vrf },
  )
}
