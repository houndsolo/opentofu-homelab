module "proxmox_fabric_macs" {
  source           = "../../modules/fabric/macs"
  nodes            = var.nodes.proxmox
  underlay_bridges = var.fabric_vms.underlay_bridges
}

# Two blocks because a provider alias cannot be chosen per instance.
module "vm" {
  source   = "../../modules/proxmox/vm"
  for_each = { for name, node in var.nodes.proxmox : name => node if !node.standalone }

  name        = "${var.fabric_vms.hostname_prefix}${each.key}"
  vm          = local.fabric_vms[each.key]
  vm_config   = var.vm_config
  ssh_pubkeys = local.ssh_pubkeys
  vm_images   = var.vm_images
}

module "greatfox_vm" {
  source   = "../../modules/proxmox/vm"
  for_each = { for name, node in var.nodes.proxmox : name => node if node.standalone }

  providers = {
    proxmox = proxmox.greatfox
  }

  name        = "${var.fabric_vms.hostname_prefix}${each.key}"
  vm          = local.fabric_vms[each.key]
  vm_config   = var.vm_config
  ssh_pubkeys = local.ssh_pubkeys
  vm_images   = var.vm_images
}
