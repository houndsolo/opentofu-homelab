module "proxmox_fabric_macs" {
  source           = "../../modules/fabric/macs"
  nodes            = var.nodes.proxmox
  underlay_bridges = var.fabric_vms.underlay_bridges
}

module "leaf" {
  source   = "../../modules/fabric/leaf"
  for_each = local.leaves
  name     = each.key
  leaf     = each.value
  fabric   = var.fabric
  vnis     = var.vnis
  l2vnis   = var.l2vnis
  radius = contains(nonsensitive(keys(var.radius_client_secrets)), "leaf-${each.value.id}") && length(var.radius_servers) > 0 ? {
    servers = var.radius_servers
    secret  = var.radius_client_secrets["leaf-${each.value.id}"]
  } : null
  fabric_macs = each.value.role == "proxmox" ? lookup(
    module.proxmox_fabric_macs.fabric_macs,
    each.key,
    {},
  ) : {}
}
