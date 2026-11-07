locals {
  system_commands = concat([
    "set system domain-name 'lylat.space'",
    "set system host-name 'LEAF-${var.leaf.id}'",
    "set system ip multipath ignore-unreachable-nexthops",
    "set system ip multipath layer4-hashing",
    ], [
    for server in var.fabric.settings.ntp_servers :
    "set service ntp server '${server}'"
  ])
}

