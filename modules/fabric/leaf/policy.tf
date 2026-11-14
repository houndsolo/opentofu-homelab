locals {
  policy_commands = local.has_vnis ? concat(
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
    "set policy prefix-list PL-DEFAULT-ROUTE rule 10 action 'permit'",
    "set policy prefix-list PL-DEFAULT-ROUTE rule 10 prefix '0.0.0.0/0'",
    "set policy prefix-list6 PL6-DEFAULT-ROUTE rule 10 action 'permit'",
    "set policy prefix-list6 PL6-DEFAULT-ROUTE rule 10 prefix '::/0'",
  ]
  policy_vrf_commands = flatten([
    #l2vni PLs
    [
      # IPv6 subnets of the L2VNIs that have an IPv6 anycast gateway.
      for vni in local.l2vnis : [
        "set policy prefix-list6 PL6-${upper(vni.vrf)}-L2VNI-SUBNETS rule ${vni.vlan_id * 10} action 'permit'",
        "set policy prefix-list6 PL6-${upper(vni.vrf)}-L2VNI-SUBNETS rule ${vni.vlan_id * 10} prefix '${cidrsubnet(vni.anycast_gw_ipv6, 0, 0)}'",
      ] if try(vni.anycast_gw_ipv6, null) != null
    ],
    [
      for vni in local.l2vnis : [
        "set policy prefix-list PL-${upper(vni.vrf)}-L2VNI-SUBNETS rule ${vni.vlan_id * 10} action 'permit'",
        "set policy prefix-list PL-${upper(vni.vrf)}-L2VNI-SUBNETS rule ${vni.vlan_id * 10} prefix '${cidrhost("${vni.anycast_gw_ip}/${vni.anycast_gw_cidr}", 0)}/${vni.anycast_gw_cidr}'",
      ]
    ],
    [
      # A VRF without L2VNIs has an empty subnet prefix-list, so rule 10 below gets no match line. Only the
      # external VRF (ext_l3) may then permit everything (it leaks fw-wan's default into the local VRFs); any
      # other empty VRF denies, or it would re-export the default it imported (DT-090: lylat_infra and
      # lylat_service re-originated 0.0.0.0/0 with RT 6200/6600 after their VLANs moved out).
      for vrf in local.role_vrfs : [
        "set policy route-map RM-${upper(vrf.vrf)}-BGP-TO-EVPN rule 10 action 'permit'",
        "set policy route-map RM-${upper(vrf.vrf)}-BGP-TO-LOCAL-VPN rule 10 action '${length(vrf.l2) > 0 || try(vrf.ext_l3, false) == true ? "permit" : "deny"}'",
        "set policy route-map RM-${upper(vrf.vrf)}-CONNECTED-TO-BGP rule 10 action '${length(vrf.l2) > 0 || try(vrf.ext_l3, false) == true ? "permit" : "deny"}'",
        "set policy route-map RM-${upper(vrf.vrf)}-CONNECTED-TO-BGP rule 100 action 'deny'",
      ]
    ],
    [
      # Only the external VRF originates 0.0.0.0/0 into EVPN. FRR re-advertises routes another VRF's RT
      # brought in, so a default in a VRF that imports other VRFs' RTs loops between leaves and VRFs and
      # sustains itself (DT-090, 2026-11-14: defaults with labels 6200/6600/6700/6900 on every leaf).
      for vrf in local.role_vrfs : [
        "set policy route-map RM-${upper(vrf.vrf)}-BGP-TO-EVPN rule 5 action 'deny'",
        "set policy route-map RM-${upper(vrf.vrf)}-BGP-TO-EVPN rule 5 match ip address prefix-list 'PL-DEFAULT-ROUTE'",
        "set policy route-map RM-${upper(vrf.vrf)}-BGP-TO-EVPN rule 6 action 'deny'",
        "set policy route-map RM-${upper(vrf.vrf)}-BGP-TO-EVPN rule 6 match ipv6 address prefix-list 'PL6-DEFAULT-ROUTE'",
      ] if try(vrf.ext_l3, false) != true
    ],
    [
      # IPv6 (step 8): rule 20 lets the VRF's IPv6 L2VNI subnets through the same route-maps (rule 10 matches
      # IPv4 only, rule 100 denies the rest); the spines get no type-5 for them either (hosts come as type-2).
      for vrf in local.role_vrfs : [
        "set policy route-map RM-${upper(vrf.vrf)}-BGP-TO-LOCAL-VPN rule 20 action 'permit'",
        "set policy route-map RM-${upper(vrf.vrf)}-BGP-TO-LOCAL-VPN rule 20 match ipv6 address prefix-list 'PL6-${upper(vrf.vrf)}-L2VNI-SUBNETS'",
        "set policy route-map RM-${upper(vrf.vrf)}-CONNECTED-TO-BGP rule 20 action 'permit'",
        "set policy route-map RM-${upper(vrf.vrf)}-CONNECTED-TO-BGP rule 20 match ipv6 address prefix-list 'PL6-${upper(vrf.vrf)}-L2VNI-SUBNETS'",
        "set policy route-map RM-EVPN-SPINE-EXPORT rule ${vrf.vni + 50} action 'deny'",
        "set policy route-map RM-EVPN-SPINE-EXPORT rule ${vrf.vni + 50} match evpn route-type 'prefix'",
        "set policy route-map RM-EVPN-SPINE-EXPORT rule ${vrf.vni + 50} match ipv6 address prefix-list 'PL6-${upper(vrf.vrf)}-L2VNI-SUBNETS'",
      ] if length([for l2 in values(try(vrf.l2, {})) : l2 if try(l2.anycast_gw_ipv6, null) != null]) > 0
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
