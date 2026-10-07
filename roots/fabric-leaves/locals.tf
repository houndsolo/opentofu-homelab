locals {
  proxmox_leaves = {
    for node_name, node in var.nodes.proxmox_cluster :
    node_name => {
      role             = "proxmox"
      proxmox_node     = node_name
      id               = node.id
      access_interface = "eth${length(var.fabric.spines) + 1}"
    }
  }

  greatfox_nodes = {
    for node_name, node in var.nodes.proxmox :
    node_name => {
      role             = "proxmox"
      proxmox_node     = node_name
      id               = node.id
      access_interface = "eth${length(var.fabric.spines) + 1}"
    }
    if name == "greatfox"
  }

  leaves = merge(var.fabric.leaves, local.proxmox_leaves, local.greatfox_nodes)
}
