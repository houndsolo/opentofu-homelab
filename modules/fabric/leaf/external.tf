locals {
  # VRFs with an external router on this leaf (external_l3 leaves only): a VLAN
  # sub-interface of the access interface in the VRF, and an unnumbered BGP
  # session to the router over it, optionally with BFD.
  ext_l3_vrfs = var.leaf.role != "external_l3" ? {} : {
    for name, vrf in local.role_vrfs : name => vrf if vrf.ext_l3 && vrf.ext_l3_peer != null
  }

  external_commands = flatten([
    for name, vrf in local.ext_l3_vrfs : [
      "set interfaces ethernet ${var.leaf.access_interface} vif ${vrf.vlan_id} description '${vrf.ext_l3_peer.description}'",
      "set interfaces ethernet ${var.leaf.access_interface} vif ${vrf.vlan_id} mtu '${var.fabric.settings.outer_mtu}'",
      "set interfaces ethernet ${var.leaf.access_interface} vif ${vrf.vlan_id} vrf '${name}'",
      "set vrf name ${name} protocols bgp neighbor ${var.leaf.access_interface}.${vrf.vlan_id} interface v6only peer-group '${vrf.ext_l3_peer.peer_group}'",
      "set vrf name ${name} protocols bgp peer-group ${vrf.ext_l3_peer.peer_group} address-family ipv4-unicast soft-reconfiguration inbound",
      "set vrf name ${name} protocols bgp peer-group ${vrf.ext_l3_peer.peer_group} capability dynamic",
      "set vrf name ${name} protocols bgp peer-group ${vrf.ext_l3_peer.peer_group} capability extended-nexthop",
      "set vrf name ${name} protocols bgp peer-group ${vrf.ext_l3_peer.peer_group} remote-as '${vrf.ext_l3_peer.remote_as}'",
      vrf.ext_l3_peer.bfd ? ["set vrf name ${name} protocols bgp peer-group ${vrf.ext_l3_peer.peer_group} bfd"] : [],
    ]
  ])
}
