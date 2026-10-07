module "proxmox_fabric_macs" {
  source                 = "../../modules/fabric/macs"
  nodes                  = var.nodes.proxmox_cluster
  underlay_bridges       = var.pve_leaf.vm_config.default_underlay_bridges
  underlay_local_as_base = var.pve_leaf.vm_config.underlay_local_as_base
}

module "vm" {
  source   = "../../modules/proxmox/vm"
  for_each = var.nodes.proxmox_cluster
  name     = "${var.pve_leaf.vm_config.hostname_prefix}${each.key}"
  vm = {
    node               = each.key
    vm_id              = each.value.id + var.pve_leaf.vm_config.vm_id_offset
    management_address = "${cidrhost(var.pve_leaf.vm_config.management_prefix, each.value.id)}/${var.pve_leaf.vm_config.management_cidr}"
    network_devices    = module.proxmox_fabric_macs.network_devices[each.key]
  }
  vm_config = var.pve_leaf.vm_config
}

module "greatfox_vm" {
  for_each = {
    for name, node in var.nodes.proxmox :
    name => node
    if name == "greatfox"
  }
  providers = { proxmox = proxmox.greatfox }
  name     = "${var.pve_leaf.vm_config.hostname_prefix}${each.key}"
  source   = "../../modules/proxmox/vm"
  vm = {
    node               = each.key
    vm_id              = each.value.id + var.pve_leaf.vm_config.vm_id_offset
    management_address = "${cidrhost(var.pve_leaf.vm_config.management_prefix, each.value.id)}/${var.pve_leaf.vm_config.management_cidr}"
    network_devices    = module.proxmox_fabric_macs.network_devices[each.key]
  }
  vm_config = var.pve_leaf.vm_config

}
