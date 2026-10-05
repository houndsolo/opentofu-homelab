output "leaf_specifications" {
  value = { for name, leaf in module.leaf : name => leaf.specification }
  precondition {
    condition = alltrue([
      for name, leaf in var.fabric.leaves : contains(keys(var.nodes.proxmox), coalesce(leaf.proxmox_node, name))
      if leaf.role == "proxmox"
    ])
    error_message = "Every proxmox-role leaf must reference a node in nodes.proxmox via proxmox_node or its inventory key."
  }
}

output "interface_binding_commands" {
  description = "VyOS hw-id commands using the same MACs as VM creation."
  value       = { for name, leaf in module.leaf : name => leaf.interface_binding_commands }
}
