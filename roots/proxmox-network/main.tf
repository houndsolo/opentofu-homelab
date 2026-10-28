module "pve_network" {
  source   = "../../modules/proxmox/network"
  for_each = { for name, node in var.nodes.proxmox : name => node if !node.standalone }

  node_name   = each.key
  node_id     = each.value.id
  pve_network = var.pve_network
}
