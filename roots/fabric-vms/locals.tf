locals {
  greatfox_nodes = {
    for node_name, node in var.nodes.proxmox :
    node_name => node
    if node_name == "greatfox"
  }
}
