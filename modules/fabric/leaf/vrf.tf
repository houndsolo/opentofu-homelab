locals {
  vrf_commands = concat(
    local.vrf_base_commands,
    local.vrf_bgp_commands,
    local.vrf_evpn_route_leak_commands,
  )
  vrf_bgp_commands = flatten([
    for vrf in local.role_vrfs : [
      "set vrf name ${vrf.vrf} protocols bgp address-family ipv4-unicast export vpn",
      "set vrf name ${vrf.vrf} protocols bgp address-family ipv4-unicast import vpn",
      "set vrf name ${vrf.vrf} protocols bgp address-family ipv4-unicast rd vpn export '${local.router_id}:${vrf.vni}'",
      "set vrf name ${vrf.vrf} protocols bgp address-family ipv4-unicast redistribute connected route-map 'RM-${upper(vrf.vrf)}-CONNECTED-TO-BGP'",
      "set vrf name ${vrf.vrf} protocols bgp address-family ipv4-unicast route-map vpn export 'RM-${upper(vrf.vrf)}-BGP-TO-LOCAL-VPN'",
      "set vrf name ${vrf.vrf} protocols bgp address-family ipv4-unicast route-target vpn export '${vrf.ipv4_rt_exports}'",
      "set vrf name ${vrf.vrf} protocols bgp address-family ipv4-unicast route-target vpn import '${vrf.ipv4_rt_imports}'",
      "set vrf name ${vrf.vrf} protocols bgp address-family l2vpn-evpn advertise ipv4 unicast route-map 'RM-${upper(vrf.vrf)}-BGP-TO-EVPN'",
      "set vrf name ${vrf.vrf} protocols bgp address-family l2vpn-evpn rd '${local.router_id}:${vrf.vni}'",
      "set vrf name ${vrf.vrf} protocols bgp parameters bestpath as-path multipath-relax",
      "set vrf name ${vrf.vrf} protocols bgp parameters router-id '${local.router_id}'",
      "set vrf name ${vrf.vrf} protocols bgp system-as '${var.fabric.overlay_as}'",
    ]
  ])
  vrf_base_commands = flatten([
    for vrf in local.role_vrfs : [
      "set vrf name ${vrf.vrf} table ${vrf.vrf_table}",
      "set vrf name ${vrf.vrf} vni ${vrf.vni}",
    ]
  ])
  vrf_evpn_route_leak_commands = flatten([
    for vrf in local.role_vrfs : [
      [
        for rt in vrf.evpn_rt_imports :
        "set vrf name ${vrf.vrf} protocols bgp address-family l2vpn-evpn route-target import '${rt}'"
      ],
      [
        for rt in vrf.evpn_rt_exports :
        "set vrf name ${vrf.vrf} protocols bgp address-family l2vpn-evpn route-target export '${rt}'"
      ],
    ]
  ])
}
