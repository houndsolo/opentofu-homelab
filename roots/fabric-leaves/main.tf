module "proxmox_fabric_macs" {
  source                 = "../../modules/fabric/macs"
  nodes                  = var.nodes.proxmox_cluster
  underlay_bridges       = var.fabric_vms.default_underlay_bridges
  underlay_local_as_base = var.fabric_vms.underlay_local_as_base
}

module "leaf" {
  source   = "../../modules/fabric/leaf"
  for_each = local.leaves
  name     = each.key
  leaf     = each.value
  fabric   = var.fabric
  vnis     = var.vnis
  fabric_macs = each.value.role == "proxmox" ? lookup(
    module.proxmox_fabric_macs.fabric_macs,
    coalesce(each.value.proxmox_node, each.key),
    {},
  ) : {}
}
