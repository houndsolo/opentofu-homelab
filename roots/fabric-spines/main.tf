module "spines" {
  source         = "../../modules/fabric/spines"
  for_each       = var.fabric.spines
  spine          = each.value
  fabric         = var.fabric
  leaves         = local.leaves
  keepalive_time = var.keepalive_time
  hold_time      = var.hold_time
  providers      = { routeros = routeros.spines[each.key] }
}
