module "leaf" {
  source = "../../modules/fabric/leaf"
  for_each = var.fabric.leaves
  name = each.key
  leaf = each.value
  overlay_as = var.fabric.overlay_as
}
