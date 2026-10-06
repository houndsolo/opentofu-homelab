locals {
  system_commands = [
    "set system domain-name 'lylat.space'",
    "set system host-name 'LEAF-${var.node.id}'",
    "set system ip multipath ignore-unreachable-nexthops",
    "set system ip multipath layer4-hashing",
  ]
}

