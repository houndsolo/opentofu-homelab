module "vm" {
  source   = "../../modules/proxmox/vm"
  for_each = var.nodes.proxmox
  name     = "${var.pve_leaf.vm_config.hostname_prefix}${each.key}"
  vm = {
    node               = each.key
    vm_id              = each.value.id + var.pve_leaf.vm_config.vm_id_offset
    management_address = "${cidrhost(var.pve_leaf.vm_config.management_prefix, each.value.id)}/${var.pve_leaf.vm_config.management_cidr}"
    network_devices = [
      for index, bridge in var.pve_leaf.vm_config.default_underlay_bridges : {
        bridge = bridge
        mac_address = join(":", regexall("..", format(
          "02%04d%04d%02d",
          var.pve_leaf.vm_config.underlay_local_as_base + each.value.id,
          each.value.id,
          index + 1,
        )))
      }
    ]
  }
  vm_config = var.pve_leaf.vm_config
}
