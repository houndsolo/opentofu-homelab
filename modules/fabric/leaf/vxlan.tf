locals {
  vxlan_commands = length(local.role_vrfs) > 0 ? flatten([
    local.vxlan_base_commands,
    local.bridge_base_commands,
    local.vni_commands,
    local.l2_vni_commands,
  ]) : []
  bridge_base_commands = [
    "set interfaces bridge br0 enable-vlan",
    "set interfaces bridge br0 ip enable-arp-accept",
    "set interfaces bridge br0 mac '${local.vtep_mac}'",
    "set interfaces bridge br0 member interface vxlan0 disable-learning",
    "set interfaces bridge br0 mtu '${var.fabric.settings.outer_mtu}'",
  ]
  vxlan_base_commands = [
    "set interfaces vxlan vxlan0 ipv6",
    "set interfaces vxlan vxlan0 mac '${local.vtep_mac}'",
    "set interfaces vxlan vxlan0 mtu '${var.fabric.settings.vxlan_mtu}'",
    "set interfaces vxlan vxlan0 parameters external",
    "set interfaces vxlan vxlan0 parameters nolearning",
    "set interfaces vxlan vxlan0 parameters vni-filter",
    "set interfaces vxlan vxlan0 source-address '${local.vtep_ipv6}'",
  ]
  vni_commands = flatten([
    for vni in local.all_vnis : [
      "set interfaces vxlan vxlan0 vlan-to-vni ${vni.vlan_id} vni '${vni.vni}'",
      "set interfaces bridge br0 vif ${vni.vlan_id} mtu '${var.fabric.settings.outer_mtu}'",
      "set interfaces bridge br0 vif ${vni.vlan_id} vrf '${vni.vrf}'",
    ]
  ])

  l2_vni_commands = [
    flatten([
      for vni in local.l2vnis : [
        "set interfaces bridge br0 member interface ${var.leaf.access_interface} allowed-vlan '${vni.vlan_id}'",
        "set interfaces pseudo-ethernet peth${vni.vni} address '${vni.anycast_gw_ip}/${vni.anycast_gw_cidr}'",
        "set interfaces pseudo-ethernet peth${vni.vni} anycast-gateway",
        "set interfaces pseudo-ethernet peth${vni.vni} ip disable-arp-filter",
        "set interfaces pseudo-ethernet peth${vni.vni} ip enable-arp-accept",
        "set interfaces pseudo-ethernet peth${vni.vni} mac '${vni.anycast_mac}'",
        "set interfaces pseudo-ethernet peth${vni.vni} source-interface 'br0.${vni.vlan_id}'",
        "set interfaces pseudo-ethernet peth${vni.vni} vrf '${vni.vrf}'",
      ]
    ])
  ]
}
