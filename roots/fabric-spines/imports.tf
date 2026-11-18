# RouterOS singletons the spine module manages but can't create: adopt them on every spine. An import of an
# object that is already in state is a no-op, so these stay (a rebuilt spine is adopted the same way).
import {
  for_each = var.fabric.spines
  to       = module.spines[each.key].routeros_ipv6_neighbor_discovery.default_all
  id       = "interface=all"
}

import {
  for_each = var.fabric.spines
  to       = module.spines[each.key].routeros_interface_ethernet_switch.l3hw
  id       = "*0" # the only switch chip on a CRS326
}
