module "pve_network" {
  source   = "../../modules/proxmox/network"
  for_each = var.nodes.proxmox

  node_name   = each.key
  node_id     = each.value.id
  pve_network = var.pve_network
}
