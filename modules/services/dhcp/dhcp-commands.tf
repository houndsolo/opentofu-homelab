locals {
  # HA peer configuration; pool generation is in dhcp-pools.tf.
  dhcp_ha_commands = [
    "set service dhcp-server high-availability mode 'active-passive'",
    "set service dhcp-server high-availability name 'vyos-DHCP-${var.ha.peer_slot}'",
    "set service dhcp-server high-availability remote '${cidrhost(var.dhcp_ha_subnet, var.ha.peer_slot)}'",
    "set service dhcp-server high-availability source-address '${cidrhost(var.dhcp_ha_subnet, var.ha.address_slot)}'",
    "set service dhcp-server high-availability status '${var.ha.role}'",
  ]

  # Reuse the VM/VyOS NIC map, rather than guessing ethN from VNI map order.
  dhcp_listen_commands = [
    for interface in keys(var.fabric_macs) :
    "set service dhcp-server listen-interface '${interface}'"
  ]

  dhcp_networks = {
    for l2 in flatten([
      for l3 in var.vnis : [
        for l2 in values(l3.l2) : l2 if try(l2.dhcp.scope, null) != null
      ]
      ]) : "l2vni${l2.vni}" => {
      vni           = l2.vni
      subnet        = "${cidrhost("${l2.anycast_gw_ip}/${l2.anycast_gw_cidr}", 0)}/${l2.anycast_gw_cidr}"
      gateway       = l2.anycast_gw_ip
      ranges        = l2.dhcp.scope.ranges
      lease         = coalesce(l2.dhcp.scope.lease_seconds, 86400)
      authoritative = coalesce(l2.dhcp.scope.authoritative, true)
      domain_name   = coalesce(l2.dhcp.scope.domain_name, var.default_domain)
      domain_search = l2.dhcp.scope.domain_search != null ? l2.dhcp.scope.domain_search : [coalesce(l2.dhcp.scope.domain_name, var.default_domain)]
      name_servers  = l2.dhcp.scope.name_servers != null ? l2.dhcp.scope.name_servers : var.default_name_servers
    }
  }

  # Keep the common CLI prefix in one place so the loops remain readable.
  dhcp_subnet_paths = {
    for name, network in local.dhcp_networks : name =>
    "service dhcp-server shared-network-name ${name} subnet ${network.subnet}"
  }

  dhcp_pool_commands = flatten([
    for name, network in local.dhcp_networks : concat(
      network.authoritative ? ["set service dhcp-server shared-network-name ${name} authoritative"] : [],
      [
        "set ${local.dhcp_subnet_paths[name]} lease '${network.lease}'",
        "set ${local.dhcp_subnet_paths[name]} option default-router '${network.gateway}'",
        "set ${local.dhcp_subnet_paths[name]} option domain-name '${network.domain_name}'",
        "set ${local.dhcp_subnet_paths[name]} subnet-id '${network.vni}'",
      ],
      [for domain in network.domain_search :
        "set ${local.dhcp_subnet_paths[name]} option domain-search '${domain}'"
      ],
      [for server in network.name_servers :
        "set ${local.dhcp_subnet_paths[name]} option name-server '${server}'"
      ],
      flatten([for range_id, pool in network.ranges : [
        "set ${local.dhcp_subnet_paths[name]} range ${range_id} start '${pool.start}'",
        "set ${local.dhcp_subnet_paths[name]} range ${range_id} stop '${pool.stop}'",
      ]]),
    )
  ])
}
