locals {
  # Servers the VyOS image ships with. Remove those not in ntp_servers so the
  # leaf only polls the configured servers.
  vyos_default_ntp_servers = [
    "0.pool.ntp.org",
    "1.pool.ntp.org",
    "time1.vyos.net",
    "time2.vyos.net",
    "time3.vyos.net",
  ]

  ntp_commands = length(var.fabric.settings.ntp_servers) == 0 ? [] : concat(
    [
      for server in var.fabric.settings.ntp_servers :
      "set service ntp server '${server}'"
    ],
    [
      for server in setsubtract(local.vyos_default_ntp_servers, var.fabric.settings.ntp_servers) :
      "delete service ntp server '${server}'"
    ],
    var.fabric.settings.leaf_ntp_vrf == null ? [] : [
      "set service ntp vrf '${var.fabric.settings.leaf_ntp_vrf}'",
    ],
  )

  system_commands = concat([
    "set system domain-name 'lylat.space'",
    "set system host-name 'LEAF-${var.leaf.id}'",
    "set system ip multipath ignore-unreachable-nexthops",
    "set system ip multipath layer4-hashing",
  ], local.ntp_commands)
}

