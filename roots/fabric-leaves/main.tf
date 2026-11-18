module "leaf" {
  source   = "../../modules/fabric/leaf"
  for_each = local.leaves
  name     = each.key
  leaf     = each.value
  fabric   = var.fabric
  vnis     = var.vnis
  l2vnis   = var.l2vnis
  radius = contains(nonsensitive(keys(var.radius_client_secrets)), "leaf-${each.value.id}") && length(var.radius_servers) > 0 ? {
    servers = var.radius_servers
    secret  = var.radius_client_secrets["leaf-${each.value.id}"]
  } : null
}
