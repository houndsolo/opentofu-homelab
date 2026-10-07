provider "routeros" {
  alias    = "spines"
  for_each = var.fabric.nodes.spines
  hosturl  = each.value.hosturl
  username = "admin"
  password = "admin"
  insecure = true
}
