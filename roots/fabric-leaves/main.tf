module "proxmox_fabric_macs" {
  source           = "../../modules/fabric/macs"
  nodes            = merge(var.nodes.proxmox_cluster, local.greatfox_nodes)
  underlay_bridges = var.fabric_vms.underlay_bridges
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
