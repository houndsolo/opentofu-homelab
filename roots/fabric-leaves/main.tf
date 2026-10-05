module "proxmox_fabric_macs" {
  source                 = "../../modules/fabric/proxmox-fabric-macs"
  nodes                  = var.nodes.proxmox
  underlay_bridges       = var.pve_leaf.vm_config.default_underlay_bridges
  underlay_local_as_base = var.pve_leaf.vm_config.underlay_local_as_base
}

module "leaf" {
  source     = "../../modules/fabric/leaf"
  for_each   = var.fabric.leaves
  name       = each.key
  leaf       = each.value
  overlay_as = var.fabric.overlay_as
  fabric_macs = each.value.role == "proxmox" ? lookup(
    module.proxmox_fabric_macs.fabric_macs,
    coalesce(each.value.proxmox_node, each.key),
    {},
  ) : {}
}
