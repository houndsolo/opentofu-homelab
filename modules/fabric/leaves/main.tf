locals {
  # Every Proxmox host runs one VyOS leaf VM (roots/fabric-vms), cabled to each
  # spine on ether<id> and to its access bridge after the spine uplinks.
  proxmox_leaves = {
    for name, node in var.nodes.proxmox : name => {
      role             = "proxmox"
      proxmox_node     = name
      id               = node.id
      access_interface = "eth${length(var.fabric.spines) + 1}"
      spine_uplink     = null
    }
  }
}

output "leaves" {
  description = "Physical fabric.leaves plus one virtual leaf per Proxmox host."
  value       = merge(var.fabric.leaves, local.proxmox_leaves)
}
