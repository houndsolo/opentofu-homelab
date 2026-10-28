module "pve_settings" {
  source   = "../../modules/proxmox/settings"
  for_each = { for name, node in var.nodes.proxmox : name => node if !node.standalone }
}
