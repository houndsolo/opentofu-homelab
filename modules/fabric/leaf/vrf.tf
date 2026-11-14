locals {
  vrf_commands = concat(
    local.vrf_base_commands,
    local.vrf_bgp_commands,
    local.vrf_bgp6_commands,
    local.vrf_evpn_route_leak_commands,
  )
  # export_vpn_ipv4 / import_ipv4_vpn gate the ipv4-unicast VPN leaking lines, so
  # a VRF with both false is isolated: it shares routes with no other VRF.
  vrf_bgp_commands = flatten([
    for vrf in local.role_vrfs : [
      vrf.export_vpn_ipv4 ? ["set vrf name ${vrf.vrf} protocols bgp address-family ipv4-unicast export vpn"] : [],
      vrf.import_ipv4_vpn ? ["set vrf name ${vrf.vrf} protocols bgp address-family ipv4-unicast import vpn"] : [],
      vrf.export_vpn_ipv4 ? ["set vrf name ${vrf.vrf} protocols bgp address-family ipv4-unicast rd vpn export '${local.router_id}:${vrf.vni}'"] : [],
      "set vrf name ${vrf.vrf} protocols bgp address-family ipv4-unicast redistribute connected route-map 'RM-${upper(vrf.vrf)}-CONNECTED-TO-BGP'",
      vrf.export_vpn_ipv4 ? [
        "set vrf name ${vrf.vrf} protocols bgp address-family ipv4-unicast route-map vpn export 'RM-${upper(vrf.vrf)}-BGP-TO-LOCAL-VPN'",
        "set vrf name ${vrf.vrf} protocols bgp address-family ipv4-unicast route-target vpn export '${vrf.ipv4_rt_exports}'",
      ] : [],
      vrf.import_ipv4_vpn ? ["set vrf name ${vrf.vrf} protocols bgp address-family ipv4-unicast route-target vpn import '${vrf.ipv4_rt_imports}'"] : [],
      "set vrf name ${vrf.vrf} protocols bgp address-family l2vpn-evpn advertise ipv4 unicast route-map 'RM-${upper(vrf.vrf)}-BGP-TO-EVPN'",
      "set vrf name ${vrf.vrf} protocols bgp address-family l2vpn-evpn rd '${local.router_id}:${vrf.vni}'",
      "set vrf name ${vrf.vrf} protocols bgp parameters bestpath as-path multipath-relax",
      "set vrf name ${vrf.vrf} protocols bgp parameters router-id '${local.router_id}'",
      "set vrf name ${vrf.vrf} protocols bgp system-as '${var.fabric.settings.overlay_as}'",
    ]
  ])
  # IPv6 (zone design step 8) in VRFs with an IPv6 anycast gateway: connected subnets into BGP, type-5/type-2
  # into EVPN with the same RTs as IPv4, and the same local VPN leaking as IPv4.
  vrf_bgp6_commands = flatten([
    for vrf in local.role_vrfs : [
      "set vrf name ${vrf.vrf} protocols bgp address-family ipv6-unicast redistribute connected route-map 'RM-${upper(vrf.vrf)}-CONNECTED-TO-BGP'",
      "set vrf name ${vrf.vrf} protocols bgp address-family l2vpn-evpn advertise ipv6 unicast route-map 'RM-${upper(vrf.vrf)}-BGP-TO-EVPN'",
      vrf.export_vpn_ipv4 ? [
        "set vrf name ${vrf.vrf} protocols bgp address-family ipv6-unicast export vpn",
        "set vrf name ${vrf.vrf} protocols bgp address-family ipv6-unicast rd vpn export '${local.router_id}:${vrf.vni}'",
        "set vrf name ${vrf.vrf} protocols bgp address-family ipv6-unicast route-map vpn export 'RM-${upper(vrf.vrf)}-BGP-TO-LOCAL-VPN'",
        "set vrf name ${vrf.vrf} protocols bgp address-family ipv6-unicast route-target vpn export '${vrf.ipv4_rt_exports}'",
      ] : [],
      vrf.import_ipv4_vpn ? [
        "set vrf name ${vrf.vrf} protocols bgp address-family ipv6-unicast import vpn",
        "set vrf name ${vrf.vrf} protocols bgp address-family ipv6-unicast route-target vpn import '${vrf.ipv4_rt_imports}'",
      ] : [],
    ] if length([for l2 in values(try(vrf.l2, {})) : l2 if try(l2.anycast_gw_ipv6, null) != null]) > 0
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
