locals {
  greatfox_nodes = {
    for name, node in var.nodes.proxmox :
    name => node
    if name == "greatfox"
  }
}
