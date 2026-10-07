module "pve_settings" {
  source   = "../../modules/proxmox/settings"
  for_each = var.nodes.proxmox_cluster

  node_name = each.key
  node_id   = each.value.id
}
