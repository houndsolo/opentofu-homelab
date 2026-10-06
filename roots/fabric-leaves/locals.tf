locals {
  proxmox_leaves = {
    for node_name, node in var.nodes.proxmox :
    node_name => {
      role             = "proxmox"
      proxmox_node     = node_name
      id               = node.id
      access_interface = "eth3"
    }
  }

  leaves = merge(var.fabric.leaves, local.proxmox_leaves)
}
