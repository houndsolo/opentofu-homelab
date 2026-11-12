locals {
  vxlan_commands = local.has_vnis ? flatten([
    local.vxlan_base_commands,
    local.bridge_base_commands,
    local.vni_commands,
    local.l2_vni_commands,
    local.l2only_vni_commands,
  ]) : []
  bridge_base_commands = [
    "set interfaces bridge br0 description 'EVPN bridge'",
    "set interfaces bridge br0 enable-vlan",
    "set interfaces bridge br0 ip enable-arp-accept",
    "set interfaces bridge br0 mac '${local.vtep_mac}'",
    "set interfaces bridge br0 member interface vxlan0 disable-learning",
    "set interfaces bridge br0 mtu '${var.fabric.settings.vxlan_mtu}'",
  ]
  vxlan_base_commands = [
    "set interfaces vxlan vxlan0 description 'VXLAN SVD'",
    "set interfaces vxlan vxlan0 ipv6",
    "set interfaces vxlan vxlan0 mac '${local.vtep_mac}'",
    "set interfaces vxlan vxlan0 mtu '${var.fabric.settings.vxlan_mtu}'",
    "set interfaces vxlan vxlan0 parameters external",
    # ARP/ND suppression (EVPN): the bridge answers ARP/NS for remote hosts from the neighbour
    # entries zebra installs from type-2 MAC+IP routes instead of flooding them to every VTEP.
    # VyOS applies it as `bridge link set dev vxlan0 neigh_suppress on learning off` when the
    # vxlan interface is configured (after the bridge, priority 460 > 319), which also re-asserts
    # learning off at boot: br0's `disable-learning` alone was lost on LEAF-20 after a reboot.
    # Any change under `vxlan0 parameters` rebuilds vxlan0 live (VyOS interfaces_vxlan.py). On
    # 2026-11-11 that left routed (L3VNI) traffic broken on the rebuilt leaves until they were
    # rebooted: after changing these parameters, reboot the leaf (one at a time).
    "set interfaces vxlan vxlan0 parameters neighbor-suppress",
    "set interfaces vxlan vxlan0 parameters nolearning",
    "set interfaces vxlan vxlan0 parameters vni-filter",
    "set interfaces vxlan vxlan0 source-address '${local.vtep_ipv6}'",
  ]
  vni_commands = flatten([
    for key, vni in local.all_vnis : [
      "set interfaces vxlan vxlan0 vlan-to-vni ${vni.vlan_id} vni '${vni.vni}'",
      "set interfaces bridge br0 vif ${vni.vlan_id} description '${contains(keys(local.l2vnis), key) ? "L2VNI" : "L3VNI"} ${vni.vni} ${vni.vrf}'",
      "set interfaces bridge br0 vif ${vni.vlan_id} mtu '${var.fabric.settings.vxlan_mtu}'",
      "set interfaces bridge br0 vif ${vni.vlan_id} vrf '${vni.vrf}'",
    ]
  ])

  l2_vni_commands = [
    flatten([
      for vni in local.l2vnis : [
        "set interfaces bridge br0 member interface ${var.leaf.access_interface} allowed-vlan '${vni.vlan_id}'",
        "set interfaces pseudo-ethernet peth${vni.vni} address '${vni.anycast_gw_ip}/${vni.anycast_gw_cidr}'",
        "set interfaces pseudo-ethernet peth${vni.vni} anycast-gateway",
        "set interfaces pseudo-ethernet peth${vni.vni} description 'anycast gw L2VNI ${vni.vni} ${vni.vrf}'",
        "set interfaces pseudo-ethernet peth${vni.vni} ip disable-arp-filter",
        "set interfaces pseudo-ethernet peth${vni.vni} ip enable-arp-accept",
        "set interfaces pseudo-ethernet peth${vni.vni} mac '${vni.anycast_mac}'",
        "set interfaces pseudo-ethernet peth${vni.vni} source-interface 'br0.${vni.vlan_id}'",
        "set interfaces pseudo-ethernet peth${vni.vni} vrf '${vni.vrf}'",
      ]
    ])
  ]

  # Standalone L2VNIs: VLAN<->VNI mapping, the access trunk, and an address-less SVI.
  # VyOS adds the vxlan0 bridge VLAN, tunnel mapping and VNI filter from vlan-to-vni.
  # The SVI carries no IPv4 and no IPv6 link-local and sits in the default VRF; it
  # exists only for FRR: zebra (10.6.1) sets an L2VNI's VLAN on VNI add only when it
  # finds an SVI, otherwise the VNI shows "Vlan: 0" and local MACs aren't advertised
  # (seen on 9214, the last VNI added). Bridge (priority 319) commits before vxlan (460),
  # so at boot the SVI exists before the mapping.
  l2only_vni_commands = flatten([
    for vni in local.role_l2only_vnis : [
      "set interfaces vxlan vxlan0 vlan-to-vni ${vni.vlan_id} vni '${vni.vni}'",
      "set interfaces bridge br0 member interface ${var.leaf.access_interface} allowed-vlan '${vni.vlan_id}'",
      "set interfaces bridge br0 vif ${vni.vlan_id} description 'HA L2VNI ${vni.vni} ${trimprefix(vni.name, "ha_")}'",
      "set interfaces bridge br0 vif ${vni.vlan_id} ipv6 address no-default-link-local",
      "set interfaces bridge br0 vif ${vni.vlan_id} mtu '${var.fabric.settings.vxlan_mtu}'",
    ]
  ])
}
