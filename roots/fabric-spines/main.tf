module "spines" {
  for_each  = { for name, node in var.fabric.nodes.spines : name => node if node.configure }
  source    = "./spines_mikrotik"
  node      = var.fabric.nodes.spines[each.key]
  providers = { routeros = routeros.spines[each.key] }
  fabric    = var.fabric
}
