module "pve_settings" {
  source   = "../../modules/proxmox/settings"
  for_each = var.nodes.proxmox_cluster
}
