locals {
  #
  # Virtual Proxmox leaves, generated from the host inventory like in
  # roots/fabric-leaves.
  #
  proxmox_leaves = {
    for node_name, node in var.nodes.proxmox_cluster :
    node_name => {
      role             = "proxmox"
      proxmox_node     = node_name
      id               = node.id
      access_interface = "eth${length(var.fabric.spines) + 1}"
    }
  }

  leaves = merge(var.fabric.leaves, local.proxmox_leaves)
}

