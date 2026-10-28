variable "routeros_username" {
  type    = string
  default = "admin"
}
variable "routeros_password" {
  type      = string
  sensitive = true
}

provider "routeros" {
  alias    = "spines"
  for_each = var.fabric.spines
  hosturl  = "http://${each.value.management_ip}"
  username = var.routeros_username
  password = var.routeros_password
  insecure = true
}
