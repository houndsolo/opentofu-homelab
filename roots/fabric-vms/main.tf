module "vm" {
  source = "../../modules/proxmox/vm"
  for_each = var.nodes.proxmox
  name = each.key
  node = each.value
}
