provider "routeros" {
  alias    = "spines"
  for_each = var.fabric.spines
  hosturl     = each.value.management_ip
  username = "admin"
  password = "admin"
  insecure = true
}
