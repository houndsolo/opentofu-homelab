locals {
  leaves = { for name, leaf in var.pve_leaf.leaves : name => leaf if leaf.is_vm }

  leaf_vms = {
    for name, leaf in local.leaves : name => {
      name               = coalesce(leaf.hostname, "${var.pve_leaf.defaults.hostname_prefix}${name}")
      node               = leaf.hypervisor_node
      vm_id              = coalesce(leaf.vm_id, leaf.id + var.pve_leaf.defaults.vm_id_offset)
      management_address = "${coalesce(leaf.management_address, cidrhost(var.pve_leaf.defaults.management_prefix, leaf.id))}/${var.pve_leaf.defaults.management_cidr}"
      gateway            = leaf.gateway
      started            = leaf.started
      tags               = leaf.tags
      cores              = leaf.cores
      memory_mb          = leaf.memory_mb
      bridge             = leaf.management_bridge
      network_devices = leaf.network_devices != null ? leaf.network_devices : [
        for index, bridge in coalesce(leaf.underlay_bridges, var.pve_leaf.defaults.default_underlay_bridges) : {
          bridge = bridge
          mac_address = lookup(leaf.fabric_macs, "eth${index + 1}", join(":", regexall("..", format(
            "02%04d%04d%02d",
            var.pve_leaf.defaults.underlay_local_as_base + leaf.id,
            leaf.id,
            index + 1,
          ))))
          vlan_id      = null
          model        = null
          mtu          = null
          disconnected = null
        }
      ]
    }
  }
}

module "vm" {
  source    = "../../modules/proxmox/vm"
  for_each  = local.leaf_vms
  name      = each.value.name
  vm        = each.value
  vm_config = var.pve_leaf.vm_config
}
