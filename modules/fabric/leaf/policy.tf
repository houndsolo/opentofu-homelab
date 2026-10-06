locals {
  policy_commands = length(local.role_vrfs) > 0 ? concat(
    local.policy_base_commands,
    local.policy_vrf_commands
  ) : []
  policy_base_commands = [
    "set policy as-path-list local_as_export rule 10 action 'permit'",
    "set policy as-path-list local_as_export rule 10 regex '^$'",
    "set policy route-map block_local_as_rm rule 10 action 'deny'",
    "set policy route-map block_local_as_rm rule 10 match as-path 'local_as_export'",
    "set policy route-map block_local_as_rm rule 100 action 'permit'",
    "set policy route-map local_as_rm rule 10 action 'permit'",
    "set policy route-map local_as_rm rule 10 match as-path 'local_as_export'",
    "set policy route-map local_as_rm rule 100 action 'deny'",
  ]
  policy_vrf_commands = flatten([
    #l2vni PLs
    [
      for vni in local.l2vnis : [
        "set policy prefix-list PL-${upper(vni.vrf)}-L2VNI-SUBNETS rule ${vni.vlan_id * 10} action 'permit'",
        "set policy prefix-list PL-${upper(vni.vrf)}-L2VNI-SUBNETS rule ${vni.vlan_id * 10} prefix '${cidrhost("${vni.anycast_gw_ip}/${vni.anycast_gw_cidr}", 0)}/${vni.anycast_gw_cidr}'",
      ]
    ],
    [
      for vrf in local.role_vrfs : [
        "set policy route-map RM-${upper(vrf.vrf)}-BGP-TO-EVPN rule 10 action 'permit'",
        "set policy route-map RM-${upper(vrf.vrf)}-BGP-TO-LOCAL-VPN rule 10 action 'permit'",
        "set policy route-map RM-${upper(vrf.vrf)}-CONNECTED-TO-BGP rule 10 action 'permit'",
        "set policy route-map RM-${upper(vrf.vrf)}-CONNECTED-TO-BGP rule 100 action 'deny'",
      ]
    ],
    [
      for vrf in local.role_vrfs : [
        "set policy route-map RM-${upper(vrf.vrf)}-BGP-TO-LOCAL-VPN rule 10 match ip address prefix-list 'PL-${upper(vrf.vrf)}-L2VNI-SUBNETS'",
        "set policy route-map RM-${upper(vrf.vrf)}-CONNECTED-TO-BGP rule 10 match ip address prefix-list 'PL-${upper(vrf.vrf)}-L2VNI-SUBNETS'",
      ] if length(vrf.l2) > 0
    ],
    [
      for vrf in local.role_vrfs : [
        "set policy route-map RM-EVPN-SPINE-EXPORT rule ${vrf.vni} action 'deny'",
        "set policy route-map RM-EVPN-SPINE-EXPORT rule ${vrf.vni} match evpn route-type 'prefix'",
        "set policy route-map RM-EVPN-SPINE-EXPORT rule ${vrf.vni} match ip address prefix-list 'PL-${upper(vrf.vrf)}-L2VNI-SUBNETS'",
      ] if length(vrf.l2) > 0
    ],
    [
      "set policy route-map RM-EVPN-SPINE-EXPORT rule 65535 action 'permit'",
    ]
  ])
}
