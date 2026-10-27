module "spines" {
  source    = "../../modules/fabric/spines"
  for_each  = var.fabric.spines
  spine     = each.value
  fabric    = var.fabric
  leaves    = local.leaves
  providers = { routeros = routeros.spines[each.key] }
}
