module "pve_settings" {
  source   = "../../modules/proxmox/settings"
  for_each = var.nodes.proxmox

  node_name   = each.key
  node_id     = each.value.id
}
